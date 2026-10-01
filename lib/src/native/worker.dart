// ignore_for_file: public_member_api_docs
// The BACnet worker isolate: owns the native stack, schedules confirmed
// requests and turns native events into Dart messages.
//
// Internal: not exported by the package.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../codec/services.dart';
import '../constants/error_codes.dart';
import '../core/exceptions.dart';
import '../core/types.dart';
import '../models/bacnet_stats.dart';
import '../models/internal/worker_message.dart';
import 'bindings.g.dart';
import 'protocol.dart';

/// Entry point of the worker isolate.
void bacnetWorkerMain(WorkerStartup startup) {
  final worker = _Worker(startup);
  final failure = worker.init();
  if (failure != null) {
    startup.mainPort.send(WorkerFailed(failure));
    Isolate.exit();
  }
  unawaited(worker.run());
}

/// Size of the native event header (bp_event_header_t).
const int _eventHeaderSize = 48;

const int _eventComplexAck = 1;
const int _eventSimpleAck = 2;
const int _eventError = 3;
const int _eventReject = 4;
const int _eventAbort = 5;
const int _eventTimeout = 6;
const int _eventUnconfirmed = 7;
const int _eventConfirmedNotification = 8;
const int _eventWrite = 9;
const int _eventLog = 10;

const int _flagAbortFromServer = 0x01;
const int _flagComplex = 0x02;

/// Packets processed per poll call before returning to the event loop.
const int _maxPacketsPerPoll = 256;

String nativeErrorMessage(int code) => switch (code) {
  BP_ERR_NOT_INITIALIZED => 'stack not initialized',
  BP_ERR_ALREADY_INITIALIZED => 'stack already initialized',
  BP_ERR_INVALID_ARGUMENT => 'invalid argument',
  BP_ERR_DATALINK => 'BACnet/IP datalink initialization failed',
  BP_ERR_NOT_BOUND => 'device address unknown',
  BP_ERR_NO_TRANSACTION => 'no free transaction',
  BP_ERR_APDU_TOO_LARGE => 'request exceeds the maximum APDU of the device',
  BP_ERR_SEND_FAILED => 'send failed',
  BP_ERR_COMMUNICATION_DISABLED => 'communication disabled (DCC)',
  BP_ERR_OBJECT => 'object operation failed',
  BP_ERR_NO_MEMORY => 'out of memory',
  BP_ERR_UNSUPPORTED => 'not supported for this object type',
  BP_ERR_SERVER_DISABLED => 'server not initialized',
  _ => 'native error $code',
};

class _Request {
  _Request(this.command, this.deadline);
  final ConfirmedRequestCommand command;
  final int deadline;
}

class _DeviceQueue {
  _DeviceQueue(this.deviceId);
  final int deviceId;
  final Queue<_Request> queue = Queue<_Request>();
  int inFlight = 0;
  bool scheduled = false;
  bool binding = false;
  int bindDeadline = 0;
  int nextWhoIs = 0;
}

class _Worker {
  _Worker(this.startup);

  final WorkerStartup startup;
  final ReceivePort _commands = ReceivePort('BacnetWorkerCommands');
  final Stopwatch _clock = Stopwatch()..start();

  final Map<int, _DeviceQueue> _devices = {};
  final Queue<_DeviceQueue> _ready = Queue<_DeviceQueue>();
  final Set<_DeviceQueue> _bindingDevices = {};
  final List<_Request?> _inFlight = List<_Request?>.filled(256, null);
  int _inFlightCount = 0;
  int _queuedCount = 0;

  int _completed = 0;
  int _failed = 0;
  int _timeouts = 0;

  bool _running = true;
  bool _busy = false;
  int _lastSweep = 0;
  List<Object> _outbox = <Object>[];

  int get _now => _clock.elapsedMilliseconds;

  static const int _scratchSize = 2048;
  final ffi.Pointer<ffi.Uint8> _scratch = calloc<ffi.Uint8>(_scratchSize);

  String? init() {
    final iface = startup.interface;
    final ifacePtr = iface == null ? ffi.nullptr : iface.toNativeUtf8();
    try {
      final rc = bacnet_plugin_init(
        ifacePtr.cast(),
        startup.port,
        startup.deviceInstance,
        startup.socketBufferSize,
      );
      if (rc != BP_OK) {
        return 'Failed to initialize BACnet/IP on '
            '${iface ?? 'default interface'}:${startup.port}: '
            '${nativeErrorMessage(rc)}';
      }
    } finally {
      if (ifacePtr != ffi.nullptr) calloc.free(ifacePtr);
    }
    bacnet_plugin_set_option(BP_OPTION_APDU_TIMEOUT_MS, startup.apduTimeoutMs);
    bacnet_plugin_set_option(BP_OPTION_APDU_RETRIES, startup.apduRetries);
    bacnet_plugin_set_option(
      BP_OPTION_STRICT_SOURCE,
      startup.strictSourceCheck ? 1 : 0,
    );
    bacnet_plugin_set_option(
      BP_OPTION_COV_SCAN_INTERVAL_MS,
      startup.covScanIntervalMs,
    );
    _commands.listen(_onCommand);
    final version = bacnet_plugin_version().cast<Utf8>().toDartString();
    startup.mainPort.send(WorkerReady(_commands.sendPort, version));
    return null;
  }

  Future<void> run() async {
    while (_running) {
      final timeout = _busy ? 0 : startup.idlePollMs;
      final processed = bacnet_plugin_poll(timeout, _maxPacketsPerPoll);
      _busy = processed >= _maxPacketsPerPoll;
      _drainEvents();
      _pump();
      final now = _now;
      if (now - _lastSweep >= 100) {
        _lastSweep = now;
        _sweep(now);
      }
      _flush();
      // let the event loop deliver commands from the main isolate
      await Future<void>.delayed(Duration.zero);
    }
    _drainEvents();
    bacnet_plugin_shutdown();
    _flush();
    _commands.close();
    calloc.free(_scratch);
  }

  // ---- outgoing messages ---------------------------------------------------

  void _emit(Object message) => _outbox.add(message);

  void _flush() {
    if (_outbox.isEmpty) return;
    startup.mainPort.send(_outbox);
    _outbox = <Object>[];
  }

  void _log(BacnetLogLevel level, String message) {
    if (level.index < startup.logLevel.index) return;
    _emit(LogResponse(levelIndex: level.index, message: message));
  }

  void _succeed(int id, [Object? value]) => _emit(CommandResult(id, value));

  void _fail(int id, Object error) => _emit(CommandFailure(id, error));

  // ---- commands --------------------------------------------------------------

  void _onCommand(Object? message) {
    if (message is! WorkerCommand) return;
    try {
      _handleCommand(message);
    } on BacnetException catch (e) {
      _fail(message.id, e);
    } on Object catch (e) {
      _fail(message.id, BacnetException('worker error: $e'));
    }
  }

  void _handleCommand(WorkerCommand command) {
    switch (command) {
      case ConfirmedRequestCommand():
        _enqueue(command);
      case UnconfirmedRequestCommand():
        _sendUnconfirmed(command);
      case BindDeviceCommand():
        _bindDevice(command);
      case UnbindDeviceCommand():
        bacnet_plugin_unbind_device(command.deviceId);
        _succeed(command.id);
      case DeviceBindingCommand():
        _deviceBinding(command);
      case RegisterForeignDeviceCommand():
        _withString(command.host, (host) {
          _check(
            bacnet_plugin_register_foreign_device(
              host,
              command.port,
              command.ttl,
            ),
          );
        });
        _succeed(command.id);
      case ServerEnableCommand():
        _serverEnable(command);
      case SendIAmCommand():
        _check(bacnet_plugin_send_i_am());
        _succeed(command.id);
      case CreateObjectCommand():
        _createObject(command);
      case DeleteObjectCommand():
        _check(
          bacnet_plugin_object_delete(command.objectType, command.instance),
        );
        _succeed(command.id);
      case SetNumberCommand():
        _check(
          bacnet_plugin_object_set_number(
            command.objectType,
            command.instance,
            command.propertyId,
            command.value,
            command.priority,
          ),
        );
        _succeed(command.id);
      case SetTextCommand():
        _setText(command);
      case SetPresentValuesCommand():
        _setPresentValues(command);
      case LocalWriteCommand():
        _localWrite(command);
      case LocalReadCommand():
        _localRead(command);
      case StatsCommand():
        _succeed(command.id, _stats());
      case ShutdownCommand():
        _shutdown();
        _succeed(command.id);
    }
    // a command may have produced work: process it without waiting
    _busy = true;
  }

  void _check(int rc) {
    if (rc < 0) {
      throw BacnetException(nativeErrorMessage(rc));
    }
  }

  T _withString<T>(String value, T Function(ffi.Pointer<ffi.Char>) body) {
    final ptr = value.toNativeUtf8();
    try {
      return body(ptr.cast());
    } finally {
      calloc.free(ptr);
    }
  }

  T _withBytes<T>(
    List<int> bytes,
    T Function(ffi.Pointer<ffi.Uint8>, int) body,
  ) {
    if (bytes.isEmpty) return body(ffi.nullptr, 0);
    if (bytes.length <= _scratchSize) {
      // hot path: reuse one native buffer (the worker is single threaded)
      _scratch.asTypedList(bytes.length).setAll(0, bytes);
      return body(_scratch, bytes.length);
    }
    final ptr = calloc<ffi.Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return body(ptr, bytes.length);
    } finally {
      calloc.free(ptr);
    }
  }

  void _sendUnconfirmed(UnconfirmedRequestCommand command) {
    final rc = _withBytes(
      command.payload,
      (data, length) => bacnet_plugin_send_unconfirmed(
        command.deviceId ?? BP_DEVICE_UNKNOWN,
        command.network,
        command.service,
        data,
        length,
      ),
    );
    if (rc < 0) {
      _fail(command.id, BacnetException(nativeErrorMessage(rc)));
    } else {
      _succeed(command.id);
    }
  }

  void _bindDevice(BindDeviceCommand command) {
    final rc = _withString(
      command.host,
      (host) => _withBytes(
        command.adr,
        (adr, length) => bacnet_plugin_bind_device(
          command.deviceId,
          host,
          command.port,
          command.network,
          adr,
          length,
          command.maxApdu,
        ),
      ),
    );
    _check(rc);
    _onDeviceBound(command.deviceId);
    _succeed(command.id);
  }

  void _deviceBinding(DeviceBindingCommand command) {
    final mac = calloc<ffi.Uint8>(8);
    final macLen = calloc<ffi.Uint8>();
    final net = calloc<ffi.Uint16>();
    final maxApdu = calloc<ffi.Uint16>();
    try {
      final bound = bacnet_plugin_device_binding(
        command.deviceId,
        mac,
        macLen,
        net,
        maxApdu,
      );
      _succeed(
        command.id,
        bound == 1
            ? <Object>[
                List<int>.of(mac.asTypedList(macLen.value)),
                net.value,
                maxApdu.value,
              ]
            : null,
      );
    } finally {
      calloc
        ..free(mac)
        ..free(macLen)
        ..free(net)
        ..free(maxApdu);
    }
  }

  void _serverEnable(ServerEnableCommand command) {
    _withString(
      command.deviceName,
      (name) => _check(bacnet_plugin_server_enable(command.deviceId, name)),
    );
    for (final entry in command.strings.entries) {
      _withString(
        entry.value,
        (value) => _check(bacnet_plugin_device_set_string(entry.key, value)),
      );
    }
    if (command.vendorId != null) {
      _check(bacnet_plugin_device_set_vendor_id(command.vendorId!));
    }
    _succeed(command.id);
  }

  void _createObject(CreateObjectCommand command) {
    final errorClass = calloc<ffi.Uint32>();
    final errorCode = calloc<ffi.Uint32>();
    int instance;
    try {
      instance = bacnet_plugin_object_create(
        command.objectType,
        command.instance,
        errorClass,
        errorCode,
      );
      if (instance < 0) {
        if (instance == BP_ERR_OBJECT) {
          throw BacnetProtocolException(
            'CreateObject ${command.objectType}:${command.instance} failed',
            errorClass: errorClass.value,
            errorCode: errorCode.value,
          );
        }
        throw BacnetException(nativeErrorMessage(instance));
      }
    } finally {
      calloc
        ..free(errorClass)
        ..free(errorCode);
    }
    final type = command.objectType;
    if (command.name != null) {
      _withString(
        command.name!,
        (v) => _check(bacnet_plugin_object_set_name(type, instance, v)),
      );
    }
    if (command.description != null) {
      _withString(
        command.description!,
        (v) => _check(bacnet_plugin_object_set_description(type, instance, v)),
      );
    }
    if (command.stateTexts != null && command.stateTexts!.isNotEmpty) {
      // NUL separated list: toNativeUtf8().length would stop at the first NUL
      final bytes = utf8.encode('${command.stateTexts!.join('\u0000')}\u0000');
      _withBytes([...bytes, 0], (data, length) {
        _check(
          bacnet_plugin_object_set_state_texts(
            type,
            instance,
            data.cast(),
            length,
          ),
        );
      });
    }
    for (final entry in command.numbers.entries) {
      _check(
        bacnet_plugin_object_set_number(
          type,
          instance,
          entry.key,
          entry.value,
          16,
        ),
      );
    }
    if (command.presentValue != null) {
      _check(
        bacnet_plugin_object_set_number(
          type,
          instance,
          85,
          command.presentValue!,
          16,
        ),
      );
    }
    if (command.presentValueString != null) {
      _withString(
        command.presentValueString!,
        (v) => _check(bacnet_plugin_object_set_string(type, instance, v)),
      );
    }
    _succeed(command.id, instance);
  }

  void _setText(SetTextCommand command) {
    _withString(command.value, (value) {
      final rc = switch (command.propertyId) {
        77 => bacnet_plugin_object_set_name(
          command.objectType,
          command.instance,
          value,
        ),
        28 => bacnet_plugin_object_set_description(
          command.objectType,
          command.instance,
          value,
        ),
        _ => bacnet_plugin_object_set_string(
          command.objectType,
          command.instance,
          value,
        ),
      };
      _check(rc);
    });
    _succeed(command.id);
  }

  void _setPresentValues(SetPresentValuesCommand command) {
    final data = command.packed.materialize().asUint8List();
    final ptr = calloc<ffi.Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      final applied = bacnet_plugin_object_set_present_values(
        ptr.cast(),
        command.count,
      );
      _check(applied);
      _succeed(command.id, applied);
    } finally {
      calloc.free(ptr);
    }
  }

  void _localWrite(LocalWriteCommand command) {
    final errorClass = calloc<ffi.Uint32>();
    final errorCode = calloc<ffi.Uint32>();
    try {
      final rc = _withBytes(
        command.payload,
        (data, length) => bacnet_plugin_object_write(
          command.objectType,
          command.instance,
          command.propertyId,
          command.arrayIndex,
          command.priority,
          data,
          length,
          errorClass,
          errorCode,
        ),
      );
      if (rc == BP_ERR_OBJECT) {
        throw BacnetProtocolException(
          'write ${command.objectType}:${command.instance} '
          'property ${command.propertyId} failed',
          errorClass: errorClass.value,
          errorCode: errorCode.value,
        );
      }
      _check(rc);
      _succeed(command.id);
    } finally {
      calloc
        ..free(errorClass)
        ..free(errorCode);
    }
  }

  void _localRead(LocalReadCommand command) {
    const capacity = 1476;
    final buffer = calloc<ffi.Uint8>(capacity);
    final errorClass = calloc<ffi.Uint32>();
    final errorCode = calloc<ffi.Uint32>();
    try {
      final length = bacnet_plugin_object_read(
        command.objectType,
        command.instance,
        command.propertyId,
        command.arrayIndex,
        buffer,
        capacity,
        errorClass,
        errorCode,
      );
      if (length == BP_ERR_OBJECT) {
        throw BacnetProtocolException(
          'read ${command.objectType}:${command.instance} '
          'property ${command.propertyId} failed',
          errorClass: errorClass.value,
          errorCode: errorCode.value,
        );
      }
      _check(length);
      final bytes = Uint8List.fromList(buffer.asTypedList(length));
      _succeed(command.id, decodeApplicationData(bytes));
    } finally {
      calloc
        ..free(buffer)
        ..free(errorClass)
        ..free(errorCode);
    }
  }

  BacnetStats _stats() {
    final stats = calloc<bp_stats_t>();
    try {
      bacnet_plugin_stats(stats);
      final s = stats.ref;
      return BacnetStats(
        queuedRequests: _queuedCount,
        inFlightRequests: _inFlightCount,
        completedRequests: _completed,
        failedRequests: _failed,
        timeouts: _timeouts,
        packetsReceived: s.packets_received,
        requestsSent: s.requests_sent,
        repliesDropped: s.replies_dropped,
        eventsDropped: s.events_dropped,
        boundDevices: s.bound_devices,
        bindingDevices: _bindingDevices.length,
        freeTransactions: s.tsm_idle,
        pollCalls: s.poll_calls,
      );
    } finally {
      calloc.free(stats);
    }
  }

  void _shutdown() {
    _running = false;
    const error = BacnetException('BACnet stack stopped');
    for (var i = 0; i < _inFlight.length; i++) {
      final request = _inFlight[i];
      if (request != null) {
        _inFlight[i] = null;
        _fail(request.command.id, error);
      }
    }
    _inFlightCount = 0;
    for (final device in _devices.values) {
      for (final request in device.queue) {
        _fail(request.command.id, error);
      }
      device.queue.clear();
    }
    _queuedCount = 0;
    _devices.clear();
    _ready.clear();
    _bindingDevices.clear();
  }

  // ---- request scheduling ----------------------------------------------------

  void _enqueue(ConfirmedRequestCommand command) {
    if (_queuedCount >= startup.maxQueued) {
      _failed++;
      _fail(
        command.id,
        BacnetQueueFullException(
          'request queue full ($_queuedCount requests waiting)',
        ),
      );
      return;
    }
    final device = _devices.putIfAbsent(
      command.deviceId,
      () => _DeviceQueue(command.deviceId),
    );
    device.queue.add(_Request(command, _now + command.timeoutMs));
    _queuedCount++;
    _schedule(device);
  }

  void _schedule(_DeviceQueue device) {
    if (!device.scheduled &&
        !device.binding &&
        device.queue.isNotEmpty &&
        device.inFlight < startup.maxInFlightPerDevice) {
      device.scheduled = true;
      _ready.addLast(device);
    }
  }

  /// Sends queued requests while transaction slots are available.
  void _pump() {
    while (_inFlightCount < startup.maxInFlight && _ready.isNotEmpty) {
      final device = _ready.removeFirst();
      device.scheduled = false;
      if (device.binding ||
          device.queue.isEmpty ||
          device.inFlight >= startup.maxInFlightPerDevice) {
        continue;
      }
      final request = device.queue.removeFirst();
      _queuedCount--;
      final now = _now;
      if (now >= request.deadline) {
        _timeouts++;
        _failed++;
        _fail(request.command.id, _expired(device));
        _schedule(device);
        continue;
      }
      final command = request.command;
      final rc = _withBytes(
        command.payload,
        (data, length) => bacnet_plugin_send_confirmed(
          command.deviceId,
          command.service,
          data,
          length,
          command.priority,
        ),
      );
      if (rc > 0) {
        if (_inFlight[rc] != null) {
          // the stack recycled the invoke id without reporting the end of
          // the previous transaction: release it instead of leaking a slot
          final stale = _takeInFlight(rc)!;
          _timeouts++;
          _failed++;
          _fail(
            stale.command.id,
            BacnetTimeoutException(
              'device ${stale.command.deviceId} did not answer',
            ),
          );
        }
        _inFlight[rc] = request;
        _inFlightCount++;
        device.inFlight++;
        _schedule(device);
        continue;
      }
      switch (rc) {
        case BP_ERR_NOT_BOUND:
          device.queue.addFirst(request);
          _queuedCount++;
          _startBinding(device, now);
        case BP_ERR_NO_TRANSACTION:
          // all invoke ids busy (e.g. server COV notifications): retry later
          device.queue.addFirst(request);
          _queuedCount++;
          _schedule(device);
          return;
        default:
          _failed++;
          _fail(command.id, BacnetException(nativeErrorMessage(rc)));
          _schedule(device);
      }
    }
  }

  void _startBinding(_DeviceQueue device, int now) {
    if (device.binding) return;
    device.binding = true;
    device.bindDeadline = now + startup.bindTimeoutMs;
    device.nextWhoIs = now;
    _bindingDevices.add(device);
    _sendBindWhoIs(device, now);
  }

  void _sendBindWhoIs(_DeviceQueue device, int now) {
    final payload = encodeWhoIs(
      lowLimit: device.deviceId,
      highLimit: device.deviceId,
    );
    _withBytes(
      payload,
      (data, length) => bacnet_plugin_send_unconfirmed(
        BP_DEVICE_UNKNOWN,
        0xFFFF,
        BacnetUnconfirmedService.whoIs,
        data,
        length,
      ),
    );
    device.nextWhoIs = now + 1000;
    _log(BacnetLogLevel.debug, 'binding device ${device.deviceId}: Who-Is');
  }

  void _onDeviceBound(int deviceId) {
    final device = _devices[deviceId];
    if (device == null || !device.binding) return;
    device.binding = false;
    _bindingDevices.remove(device);
    _schedule(device);
  }

  /// Expires queued requests and handles binding timeouts.
  void _sweep(int now) {
    if (_bindingDevices.isNotEmpty) {
      for (final device in _bindingDevices.toList()) {
        if (now >= device.bindDeadline) {
          device.binding = false;
          _bindingDevices.remove(device);
          final error = BacnetDeviceNotFoundException(
            'device ${device.deviceId} did not answer Who-Is',
            deviceId: device.deviceId,
          );
          for (final request in device.queue) {
            _failed++;
            _fail(request.command.id, error);
          }
          _queuedCount -= device.queue.length;
          device.queue.clear();
        } else if (now >= device.nextWhoIs) {
          _sendBindWhoIs(device, now);
        }
      }
    }
    if (_inFlightCount > 0) {
      // safety net: the TSM reports timeouts, but never keep a slot past
      // the request deadline plus the full retry window
      final grace = startup.apduTimeoutMs * (startup.apduRetries + 1);
      for (var invokeId = 1; invokeId < _inFlight.length; invokeId++) {
        final request = _inFlight[invokeId];
        if (request != null && now >= request.deadline + grace) {
          _takeInFlight(invokeId);
          _timeouts++;
          _failed++;
          _fail(
            request.command.id,
            BacnetTimeoutException(
              'device ${request.command.deviceId} did not answer',
            ),
          );
        }
      }
    }
    if (_queuedCount == 0) return;
    for (final device in _devices.values) {
      if (device.queue.isEmpty) continue;
      final before = device.queue.length;
      device.queue.removeWhere((request) {
        if (now < request.deadline) return false;
        _timeouts++;
        _failed++;
        _fail(request.command.id, _expired(device));
        return true;
      });
      _queuedCount -= before - device.queue.length;
    }
    // forget idle devices to bound memory
    if (_devices.length > 4096) {
      _devices.removeWhere(
        (_, d) => d.queue.isEmpty && d.inFlight == 0 && !d.binding,
      );
    }
  }

  BacnetException _expired(_DeviceQueue device) => device.binding
      ? BacnetDeviceNotFoundException(
          'device ${device.deviceId} did not answer Who-Is',
          deviceId: device.deviceId,
        )
      : const BacnetTimeoutException('request expired in the queue');

  _Request? _takeInFlight(int invokeId) {
    final request = _inFlight[invokeId];
    if (request == null) return null;
    _inFlight[invokeId] = null;
    _inFlightCount--;
    final device = _devices[request.command.deviceId];
    if (device != null) {
      device.inFlight--;
      _schedule(device);
    }
    return request;
  }

  // ---- native events ---------------------------------------------------------

  void _drainEvents() {
    final length = bacnet_plugin_events_length();
    if (length == 0) return;
    final bytes = bacnet_plugin_events_data().asTypedList(length);
    final view = ByteData.sublistView(bytes);
    var offset = 0;
    while (offset + _eventHeaderSize <= length) {
      final dataLength = view.getUint16(offset + 44, Endian.host);
      final end = offset + _eventHeaderSize + dataLength;
      if (end > length) break;
      try {
        _handleEvent(
          bytes,
          view,
          offset,
          Uint8List.sublistView(bytes, offset + _eventHeaderSize, end),
        );
      } on Object catch (e) {
        _log(BacnetLogLevel.warning, 'failed to process event: $e');
      }
      offset = end;
    }
    bacnet_plugin_events_clear();
  }

  void _handleEvent(Uint8List bytes, ByteData view, int at, Uint8List data) {
    final kind = bytes[at];
    final service = bytes[at + 1];
    final invokeId = bytes[at + 2];
    final flags = bytes[at + 3];
    switch (kind) {
      case _eventComplexAck:
        final request = _takeInFlight(invokeId);
        if (request != null) _completeAck(request, data);
      case _eventSimpleAck:
        final request = _takeInFlight(invokeId);
        if (request != null) {
          _completed++;
          _succeed(request.command.id);
        }
      case _eventError:
        final request = _takeInFlight(invokeId);
        if (request == null) return;
        var errorClass = view.getUint32(at + 8, Endian.host);
        var errorCode = view.getUint32(at + 12, Endian.host);
        if (flags & _flagComplex != 0) {
          try {
            (errorClass, errorCode) = decodeComplexError(data);
          } on BacnetDecodeException {
            errorClass = errorCode = -1;
          }
        }
        _failed++;
        _fail(
          request.command.id,
          BacnetProtocolException(
            'device ${request.command.deviceId} returned an error',
            errorClass: errorClass,
            errorCode: errorCode,
          ),
        );
      case _eventReject:
        final request = _takeInFlight(invokeId);
        if (request == null) return;
        _failed++;
        _fail(
          request.command.id,
          BacnetRejectException(
            'device ${request.command.deviceId} rejected the request',
            reason: view.getUint32(at + 8, Endian.host),
          ),
        );
      case _eventAbort:
        final request = _takeInFlight(invokeId);
        if (request == null) return;
        _failed++;
        _fail(
          request.command.id,
          BacnetAbortException(
            'transaction with device ${request.command.deviceId} aborted',
            reason: view.getUint32(at + 8, Endian.host),
            fromServer: flags & _flagAbortFromServer != 0,
          ),
        );
      case _eventTimeout:
        final request = _takeInFlight(invokeId);
        if (request == null) return;
        _timeouts++;
        _failed++;
        _fail(
          request.command.id,
          BacnetTimeoutException(
            'device ${request.command.deviceId} did not answer',
          ),
        );
      case _eventUnconfirmed:
        _handleUnconfirmed(bytes, view, at, service, data);
      case _eventConfirmedNotification:
        if (service == BacnetConfirmedService.covNotification) {
          _emitCov(data, confirmed: true);
        } else {
          _emit(
            UnconfirmedServiceResponse(
              service: service,
              data: Uint8List.fromList(data),
              mac: _mac(bytes, at),
              net: view.getUint16(at + 26, Endian.host),
              confirmed: true,
            ),
          );
        }
      case _eventWrite:
        final raw = Uint8List.fromList(data);
        Object? value;
        try {
          value = decodeApplicationData(raw);
        } on BacnetDecodeException {
          value = raw;
        }
        _emit(
          WriteNotificationResponse(
            objectType: view.getUint32(at + 8, Endian.host),
            instance: view.getUint32(at + 12, Endian.host),
            propertyId: view.getUint32(at + 16, Endian.host),
            index: view.getInt32(at + 20, Endian.host),
            priority: bytes[at + 24],
            value: value,
            rawValue: raw,
          ),
        );
      case _eventLog:
        final level = view.getUint32(at + 8, Endian.host);
        _log(
          BacnetLogLevel.values[level.clamp(0, 3)],
          String.fromCharCodes(data),
        );
    }
  }

  List<int> _mac(Uint8List bytes, int at) {
    final length = bytes[at + 25].clamp(0, 7);
    return List<int>.of(
      Uint8List.sublistView(bytes, at + 28, at + 28 + length),
    );
  }

  void _completeAck(_Request request, Uint8List data) {
    final command = request.command;
    try {
      final Object? value = switch (command.decoding) {
        AckDecoding.none => null,
        AckDecoding.raw => Uint8List.fromList(data),
        AckDecoding.readProperty => decodeReadPropertyAck(data).value,
        AckDecoding.readPropertyMultiple => decodeReadPropertyMultipleAck(data),
        AckDecoding.readRange => decodeReadRangeAck(data),
      };
      _completed++;
      _succeed(command.id, value);
    } on BacnetDecodeException catch (e) {
      _failed++;
      _fail(command.id, e);
    }
  }

  void _handleUnconfirmed(
    Uint8List bytes,
    ByteData view,
    int at,
    int service,
    Uint8List data,
  ) {
    switch (service) {
      case BacnetUnconfirmedService.iAm:
        final deviceId = view.getUint32(at + 4, Endian.host);
        final srcLength = bytes[at + 35].clamp(0, 7);
        _emit(
          IAmResponse(
            deviceId: deviceId,
            net: view.getUint16(at + 26, Endian.host),
            mac: _mac(bytes, at),
            len: data.length,
            maxApdu: view.getUint32(at + 8, Endian.host),
            vendorId: view.getUint32(at + 12, Endian.host),
            segmentation: view.getUint32(at + 16, Endian.host),
            adr: List<int>.of(
              Uint8List.sublistView(bytes, at + 36, at + 36 + srcLength),
            ),
          ),
        );
        _onDeviceBound(deviceId);
      case BacnetUnconfirmedService.covNotification:
        _emitCov(data, confirmed: false);
      default:
        _emit(
          UnconfirmedServiceResponse(
            service: service,
            data: Uint8List.fromList(data),
            mac: _mac(bytes, at),
            net: view.getUint16(at + 26, Endian.host),
          ),
        );
    }
  }

  void _emitCov(Uint8List data, {required bool confirmed}) {
    try {
      final cov = decodeCovNotification(data);
      _emit(
        COVNotificationResponse(
          objectType: cov.monitoredObject.type,
          instance: cov.monitoredObject.instance,
          timestamp: DateTime.now().toIso8601String(),
          deviceId: cov.initiatingDeviceId,
          subscriberProcessId: cov.subscriberProcessId,
          timeRemaining: cov.timeRemaining,
          values: {for (final v in cov.values) v.propertyId: v.value},
          confirmed: confirmed,
        ),
      );
    } on BacnetDecodeException catch (e) {
      _log(BacnetLogLevel.warning, 'malformed COV notification: $e');
    }
  }
}
