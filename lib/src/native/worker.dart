// The BACnet worker isolate: owns the native engine, schedules confirmed
// requests and turns native events into Dart messages.
//
// Internal: not exported by the package.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../codec/requests.dart';
import '../codec/responses.dart';
import '../codec/value_encoding.dart';
import '../constants/enumerations.dart';
import '../constants/errors.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../constants/services.dart';
import '../core/exceptions.dart';
import '../core/types.dart';
import '../models/bacnet_stats.dart';
import '../models/bacnet_value.dart';
import '../models/events.dart';
import 'bindings.g.dart';
import 'engine.dart';
import 'native_event.dart';
import 'protocol.dart';
import 'scheduler.dart';

/// Entry point of the worker isolate.
void bacnetWorkerMain(WorkerStartup startup) {
  final worker = _Worker(startup);
  try {
    worker.init();
  } on BacnetException catch (e) {
    startup.mainPort.send(WorkerFailed(e.message));
    Isolate.exit();
  }
  unawaited(worker.run());
}

/// Packets processed per poll call before returning to the event loop.
const int _maxPacketsPerPoll = 256;

/// Interval of the scheduler housekeeping.
const int _sweepIntervalMs = 100;

final class _Worker implements RequestTransport {
  _Worker(this.startup);

  final WorkerStartup startup;
  final NativeEngine _engine = NativeEngine();
  final ReceivePort _commands = ReceivePort('BacnetWorkerCommands');
  final Stopwatch _clock = Stopwatch()..start();
  late final RequestScheduler _scheduler = RequestScheduler(
    transport: this,
    onFailure: _requestFailed,
    maxInFlight: startup.maxInFlight,
    maxInFlightPerDevice: startup.maxInFlightPerDevice,
    maxQueued: startup.maxQueued,
    bindTimeoutMs: startup.bindTimeoutMs,
    retryWindowMs: startup.apduTimeoutMs * (startup.apduRetries + 1),
    offlineAfterTimeouts: startup.offlineAfterTimeouts,
    offlineRetryMs: startup.offlineRetryMs,
    clock: () => _clock.elapsedMilliseconds,
  );

  int _completed = 0;
  int _failed = 0;
  int _timeouts = 0;

  bool _running = true;
  bool _busy = false;
  int _lastSweep = 0;
  List<Object> _outbox = <Object>[];

  void init() {
    _engine.init(
      interface: startup.interface,
      port: startup.port,
      deviceInstance: startup.deviceInstance,
      socketBufferSize: startup.socketBufferSize,
    );
    try {
      _engine.configure(
        apduTimeoutMs: startup.apduTimeoutMs,
        apduRetries: startup.apduRetries,
        strictSourceCheck: startup.strictSourceCheck,
        covScanIntervalMs: startup.covScanIntervalMs,
        maxSegments: startup.maxSegments,
      );
    } on BacnetException {
      _engine.shutdown();
      rethrow;
    }
    _commands.listen(_onCommand);
    startup.mainPort.send(WorkerReady(_commands.sendPort, _engine.version));
  }

  Future<void> run() async {
    while (_running) {
      final processed = _engine.poll(
        _busy ? 0 : startup.idlePollMs,
        _maxPacketsPerPoll,
      );
      _busy = processed >= _maxPacketsPerPoll;
      _drainEvents();
      _scheduler.pump();
      final now = _clock.elapsedMilliseconds;
      if (now - _lastSweep >= _sweepIntervalMs) {
        _lastSweep = now;
        _scheduler.sweep();
      }
      _flush();
      // let the event loop deliver commands from the main isolate
      await Future<void>.delayed(Duration.zero);
    }
    _drainEvents();
    _engine.shutdown();
    _flush();
    _commands.close();
  }

  // ---- RequestTransport ------------------------------------------------------

  @override
  int sendConfirmed(ConfirmedRequestCommand command) => _engine.sendConfirmed(
    command.deviceId,
    command.service,
    command.payload,
    command.priority,
  );

  @override
  void requestBinding(int deviceId) {
    _log(BacnetLogLevel.debug, 'binding device $deviceId: Who-Is');
    try {
      _engine.sendUnconfirmed(
        BacnetUnconfirmedService.whoIs,
        encodeWhoIs(lowLimit: deviceId, highLimit: deviceId),
      );
    } on BacnetException catch (e) {
      _log(BacnetLogLevel.warning, 'Who-Is for device $deviceId failed: $e');
    }
  }

  // ---- outgoing messages -----------------------------------------------------

  void _emit(Object message) => _outbox.add(message);

  void _flush() {
    if (_outbox.isEmpty) return;
    startup.mainPort.send(_outbox);
    _outbox = <Object>[];
  }

  void _log(BacnetLogLevel level, String message) {
    if (level.index < startup.logLevel.index) return;
    _emit(LogEvent(levelIndex: level.index, message: message));
  }

  void _requestSucceeded(ConfirmedRequestCommand command, [Object? value]) {
    _completed++;
    _emit(CommandResult(command.id, value));
  }

  void _requestFailed(ConfirmedRequestCommand command, BacnetException error) {
    _failed++;
    if (error is BacnetTimeoutException) _timeouts++;
    _emit(CommandFailure(command.id, error));
  }

  // ---- commands --------------------------------------------------------------

  void _onCommand(Object? message) {
    if (message is! WorkerCommand) return;
    if (message is ConfirmedRequestCommand) {
      // answered once the device replies (or the scheduler gives up)
      _scheduler.enqueue(message);
    } else if (message is CancelRequestCommand) {
      _scheduler.cancel(message.requestId);
    } else {
      try {
        _emit(CommandResult(message.id, _execute(message)));
      } on BacnetException catch (e) {
        _emit(CommandFailure(message.id, e));
      } on Object catch (e) {
        _emit(CommandFailure(message.id, BacnetException('worker error: $e')));
      }
    }
    // a command may have produced work: process it without waiting
    _busy = true;
  }

  /// Executes a command that completes immediately and returns its result.
  Object? _execute(WorkerCommand command) {
    switch (command) {
      case ConfirmedRequestCommand() || CancelRequestCommand():
        throw StateError('handled by the scheduler');
      case UnconfirmedRequestCommand():
        _engine.sendUnconfirmed(
          command.service,
          command.payload,
          deviceId: command.deviceId,
          network: command.network,
        );
      case BindDeviceCommand():
        _engine.bindDevice(
          deviceId: command.deviceId,
          host: command.host,
          port: command.port,
          network: command.network,
          adr: command.adr,
          maxApdu: command.maxApdu,
        );
        _scheduler.deviceBound(command.deviceId);
      case UnbindDeviceCommand():
        _engine.unbindDevice(command.deviceId);
      case DeviceBindingCommand():
        final binding = _engine.deviceBinding(command.deviceId);
        return binding == null
            ? null
            : <Object>[binding.mac, binding.network, binding.maxApdu];
      case RegisterForeignDeviceCommand():
        _engine.registerForeignDevice(command.host, command.port, command.ttl);
      case ServerEnableCommand():
        _engine.enableServer(command.deviceId, command.deviceName);
        for (final MapEntry(:key, :value) in command.strings.entries) {
          _engine.setDeviceString(key, value);
        }
        if (command.vendorId case final vendorId?) {
          _engine.setVendorId(vendorId);
        }
      case SendIAmCommand():
        _engine.sendIAm();
      case CreateObjectCommand():
        return _createObject(command);
      case DeleteObjectCommand():
        _engine.deleteObject(command.objectType, command.instance);
      case SetNumberCommand():
        _engine.setNumber(
          command.objectType,
          command.instance,
          command.propertyId,
          command.value,
          command.priority,
        );
      case SetTextCommand():
        _engine.setObjectText(
          command.objectType,
          command.instance,
          command.propertyId,
          command.value,
        );
      case SetPresentValuesCommand():
        return _engine.setPresentValues(
          command.packed.materialize().asUint8List(),
          command.count,
        );
      case LocalWriteCommand():
        _engine.writeProperty(
          objectType: command.objectType,
          instance: command.instance,
          propertyId: command.propertyId,
          payload: command.payload,
          arrayIndex: command.arrayIndex,
          priority: command.priority,
        );
      case LocalReadCommand():
        return decodeApplicationData(
          _engine.readProperty(
            objectType: command.objectType,
            instance: command.instance,
            propertyId: command.propertyId,
            arrayIndex: command.arrayIndex,
          ),
        );
      case StatsCommand():
        return _stats();
      case ShutdownCommand():
        _running = false;
        _scheduler.cancelAll(const BacnetException('BACnet stack stopped'));
    }
    return null;
  }

  int _createObject(CreateObjectCommand command) {
    final type = command.objectType;
    final instance = _engine.createObject(type, command.instance);
    if (command.name case final name?) {
      _engine.setObjectText(type, instance, BacnetPropertyId.objectName, name);
    }
    if (command.description case final description?) {
      _engine.setObjectText(
        type,
        instance,
        BacnetPropertyId.description,
        description,
      );
    }
    if (command.stateTexts case final states? when states.isNotEmpty) {
      _engine.setStateTexts(type, instance, states);
    }
    for (final MapEntry(:key, :value) in command.numbers.entries) {
      _engine.setNumber(type, instance, key, value);
    }
    if (command.presentValue case final value?) {
      _engine.setNumber(type, instance, BacnetPropertyId.presentValue, value);
    }
    if (command.presentValueString case final value?) {
      _engine.setObjectText(
        type,
        instance,
        BacnetPropertyId.presentValue,
        value,
      );
    }
    return instance;
  }

  BacnetStats _stats() {
    final native = _engine.stats();
    return BacnetStats(
      queuedRequests: _scheduler.queued,
      inFlightRequests: _scheduler.inFlight,
      completedRequests: _completed,
      failedRequests: _failed,
      timeouts: _timeouts,
      packetsReceived: native.packetsReceived,
      requestsSent: native.requestsSent,
      repliesDropped: native.repliesDropped,
      eventsDropped: native.eventsDropped,
      boundDevices: native.boundDevices,
      bindingDevices: _scheduler.binding,
      offlineDevices: _scheduler.offline,
      segmentedReplies: native.segmentedReplies,
      freeTransactions: native.freeTransactions,
      pollCalls: native.pollCalls,
    );
  }

  // ---- native events ---------------------------------------------------------

  void _drainEvents() {
    final buffer = _engine.eventsView();
    if (buffer.isEmpty) return;
    for (final event in readNativeEvents(buffer)) {
      try {
        _handleEvent(event);
      } on Object catch (e) {
        _log(BacnetLogLevel.warning, 'failed to process event: $e');
      }
    }
    _engine.clearEvents();
  }

  void _handleEvent(NativeEvent event) {
    switch (event.kind) {
      case BP_EVENT_COMPLEX_ACK:
        if (_scheduler.complete(event.invokeId) case final command?) {
          _completeAck(command, event.data);
        }
      case BP_EVENT_SIMPLE_ACK:
        if (_scheduler.complete(event.invokeId) case final command?) {
          _requestSucceeded(command);
        }
      case BP_EVENT_ERROR || BP_EVENT_REJECT || BP_EVENT_ABORT:
        if (_scheduler.complete(event.invokeId) case final command?) {
          _requestFailed(command, _failure(command.deviceId, event));
        }
      case BP_EVENT_TIMEOUT:
        final command = _scheduler.complete(event.invokeId, answered: false);
        if (command != null) {
          _requestFailed(command, _failure(command.deviceId, event));
        }
      case BP_EVENT_UNCONFIRMED:
        _handleUnconfirmed(event);
      case BP_EVENT_CONFIRMED_NOTIFICATION:
        if (event.service == BacnetConfirmedService.covNotification) {
          _emitCov(event.data, confirmed: true);
        } else {
          _emit(_serviceEvent(event, confirmed: true));
        }
      case BP_EVENT_WRITE:
        _emit(_writeEvent(event));
      case BP_EVENT_LOG:
        _log(
          BacnetLogLevel.values[event.a.clamp(0, 3)],
          String.fromCharCodes(event.data),
        );
    }
  }

  BacnetException _failure(int deviceId, NativeEvent event) {
    switch (event.kind) {
      case BP_EVENT_ERROR:
        var error = BacnetError(
          BacnetErrorClass(event.a),
          BacnetErrorCode(event.b),
        );
        if (event.hasFlag(BP_FLAG_COMPLEX)) {
          try {
            error = decodeComplexError(event.data);
          } on BacnetDecodeException {
            error = const BacnetError(
              BacnetErrorClass(-1),
              BacnetErrorCode(-1),
            );
          }
        }
        return BacnetProtocolException(
          'device $deviceId returned an error',
          errorClass: error.errorClass,
          errorCode: error.errorCode,
        );
      case BP_EVENT_REJECT:
        return BacnetRejectException(
          'device $deviceId rejected the request',
          reason: BacnetRejectReason(event.a),
        );
      case BP_EVENT_ABORT:
        return BacnetAbortException(
          'transaction with device $deviceId aborted',
          reason: BacnetAbortReason(event.a),
          fromServer: event.hasFlag(BP_FLAG_ABORT_FROM_SERVER),
        );
      default:
        return BacnetTimeoutException('device $deviceId did not answer');
    }
  }

  void _completeAck(ConfirmedRequestCommand command, Uint8List data) {
    try {
      final Object? value = switch (command.decoding) {
        AckDecoding.none => null,
        AckDecoding.raw => Uint8List.fromList(data),
        AckDecoding.readProperty => decodeReadPropertyAck(data).value,
        AckDecoding.readPropertyMultiple => decodeReadPropertyMultipleAck(data),
        AckDecoding.readRange => decodeReadRangeAck(data),
      };
      _requestSucceeded(command, value);
    } on BacnetDecodeException catch (e) {
      _requestFailed(command, e);
    }
  }

  void _handleUnconfirmed(NativeEvent event) {
    switch (event.service) {
      case BacnetUnconfirmedService.iAm:
        _emit(
          IAmEvent(
            deviceId: event.deviceId,
            net: event.sourceNetwork,
            mac: event.sourceMac,
            len: event.data.length,
            maxApdu: event.a,
            vendorId: event.b,
            segmentation: BacnetSegmentation(event.c),
            adr: event.sourceAdr,
          ),
        );
        _scheduler.deviceBound(event.deviceId);
      case BacnetUnconfirmedService.covNotification:
        _emitCov(event.data, confirmed: false);
      default:
        _emit(_serviceEvent(event, confirmed: false));
    }
  }

  UnconfirmedServiceEvent _serviceEvent(
    NativeEvent event, {
    required bool confirmed,
  }) => UnconfirmedServiceEvent(
    service: event.service,
    data: Uint8List.fromList(event.data),
    mac: event.sourceMac,
    net: event.sourceNetwork,
    confirmed: confirmed,
  );

  PropertyWriteEvent _writeEvent(NativeEvent event) {
    final raw = Uint8List.fromList(event.data);
    BacnetValue? value;
    try {
      value = decodeApplicationData(raw);
    } on BacnetDecodeException {
      value = null;
    }
    return PropertyWriteEvent(
      objectType: BacnetObjectType(event.a),
      instance: event.b,
      propertyId: BacnetPropertyId(event.c),
      index: event.d,
      priority: event.priority,
      value: value,
      rawValue: raw,
    );
  }

  void _emitCov(Uint8List data, {required bool confirmed}) {
    try {
      final cov = decodeCovNotification(data);
      _emit(
        CovNotificationEvent(
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
