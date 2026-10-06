// The BACnet worker isolate: owns the native engine, schedules confirmed
// requests and turns native events into Dart messages.
//
// Internal: not exported by the package.

import 'dart:async';
import 'dart:isolate';
import 'dart:math';
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
import '../models/cov_multiple.dart';
import '../models/events.dart';
import '../models/network.dart';
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
      useIPv6: startup.useIPv6,
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
          mac: command.mac,
          adr: command.adr,
        );
      case NetworkMessageCommand():
        _engine.sendNetworkMessage(
          messageType: command.messageType,
          payload: command.payload,
          mac: command.mac,
          network: command.network,
          adr: command.adr,
          vendorId: command.vendorId,
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
      case LocalAddressCommand():
        return _engine.localAddress();
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
        _engine.setPassword(_password(command.password));
      case SetDeviceInstanceCommand(:final deviceId):
        _engine.setDeviceInstance(deviceId);
      case SetPasswordCommand(:final password):
        _engine.setPassword(_password(password));
      case SendIAmCommand():
        _engine.sendIAm();
      case CreateObjectCommand():
        return _createObject(command);
      case DeleteObjectCommand():
        _engine.deleteObject(command.objectType, command.instance);
      case TrendLogAppendCommand(
        :final instance,
        :final payload,
        :final statusFlags,
      ):
        return _engine.appendTrendLog(instance, payload, statusFlags);
      case BackupConfigureCommand(
        :final files,
        :final prepare,
        :final apply,
        :final failureTimeoutSeconds,
      ):
        _engine.configureBackup(
          files,
          prepare: prepare,
          apply: apply,
          failureTimeoutSeconds: failureTimeoutSeconds,
        );
      case BackupStateCommand(:final state):
        _engine.setBackupState(state);
      case SetFileContentCommand(:final instance, :final content):
        _engine.setFileContent(instance, content);
      case FileContentCommand(:final instance):
        return _engine.fileContent(instance);
      case ConfigureFileCommand(
        :final instance,
        :final fileType,
        :final readOnly,
        :final maxSize,
      ):
        _engine.configureFile(
          instance,
          fileType: fileType,
          readOnly: readOnly,
          maxSize: maxSize,
        );
      case TimeMasterCommand(
        :final enabled,
        :final intervalSeconds,
        :final utc,
        :final align,
        :final offsetSeconds,
        :final recipients,
      ):
        _engine.configureTimeMaster(
          enabled: enabled,
          intervalSeconds: intervalSeconds,
          utc: utc,
          align: align,
          offsetSeconds: offsetSeconds,
          recipients: [
            for (final r in recipients)
              (
                deviceId: r.deviceId,
                mac: r.mac,
                network: r.network,
                adr: r.adr,
              ),
          ],
        );
      case AuditLogConfigureCommand():
        _engine.configureAuditLog(command.instance, enabled: command.enabled);
      case AuditReporterConfigureCommand():
        _engine.configureAuditReporter(
          command.instance,
          auditLevel: command.auditLevel,
          operations: command.operations,
          auditLogInstance: command.auditLogInstance,
          maxSendDelaySeconds: command.maxSendDelaySeconds,
          recipient: command.recipient == null
              ? null
              : (
                  deviceId: command.recipient!.deviceId,
                  mac: command.recipient!.mac,
                  network: command.recipient!.network,
                  adr: command.recipient!.adr,
                ),
        );
      case EventEnrollmentCommand():
        _engine.configureEventEnrollment(
          command.instance,
          monitoredType: command.monitoredType,
          monitoredInstance: command.monitoredInstance,
          monitoredProperty: command.monitoredProperty,
          monitoredIndex: command.monitoredIndex,
          lowLimit: command.lowLimit,
          highLimit: command.highLimit,
          deadband: command.deadband,
          timeDelaySeconds: command.timeDelaySeconds,
          notificationClass: command.notificationClass,
          eventEnable: command.eventEnable,
          notifyType: command.notifyType,
        );
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

  /// [password], or a random one nobody knows: bacnet-stack would accept
  /// its well-known default password otherwise.
  static String _password(String? password) {
    if (password != null) return password;
    final random = Random.secure();
    return String.fromCharCodes(
      List.generate(20, (_) => 0x21 + random.nextInt(0x5E)),
    );
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
        switch (event.service) {
          case BacnetConfirmedService.covNotification:
            _emitCov(event.data, confirmed: true);
          case BacnetConfirmedService.covNotificationMultiple:
            _emitCovMultiple(event.data, confirmed: true);
          case BacnetConfirmedService.eventNotification:
            _emit(_eventNotification(event, confirmed: true));
          case BacnetConfirmedService.auditNotification:
            _emit(_auditNotification(event, confirmed: true));
          default:
            _emit(_serviceEvent(event, confirmed: true));
        }
      case BP_EVENT_WRITE:
        _emit(_writeEvent(event));
      case BP_EVENT_SERVICE:
        _emit(_serviceRequestEvent(event));
      case BP_EVENT_NETWORK:
        _networkMessage(event);
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
        int? firstFailedElement;
        BacnetFailedCovSubscription? firstFailedSubscription;
        if (event.hasFlag(BP_FLAG_COMPLEX)) {
          try {
            (:error, :firstFailedElement, :firstFailedSubscription) =
                decodeComplexError(event.data, service: event.service);
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
          firstFailedElement: firstFailedElement,
          firstFailedSubscription: firstFailedSubscription,
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
        AckDecoding.getEventInformation => decodeGetEventInformationAck(data),
        AckDecoding.getAlarmSummary => decodeGetAlarmSummaryAck(data),
        AckDecoding.getEnrollmentSummary => decodeGetEnrollmentSummaryAck(data),
        AckDecoding.auditLogQuery => decodeAuditLogQueryAck(data),
        AckDecoding.createObject => decodeCreateObjectAck(data),
        AckDecoding.atomicReadFile => decodeAtomicReadFileAck(data),
        AckDecoding.atomicWriteFile => decodeAtomicWriteFileAck(data),
        AckDecoding.privateTransfer => decodePrivateTransfer(data).parameters,
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
      case BacnetUnconfirmedService.covNotificationMultiple:
        _emitCovMultiple(event.data, confirmed: false);
      case BacnetUnconfirmedService.eventNotification:
        _emit(_eventNotification(event, confirmed: false));
      case BacnetUnconfirmedService.auditNotification:
        _emit(_auditNotification(event, confirmed: false));
      default:
        _emit(_unconfirmedEvent(event));
    }
  }

  /// The typed event of an unconfirmed service, or the raw request when it
  /// is not decoded or malformed.
  BacnetEvent _unconfirmedEvent(NativeEvent event) {
    try {
      switch (event.service) {
        case BacnetUnconfirmedService.iHave:
          final i = decodeIHave(event.data);
          return IHaveEvent(
            deviceId: i.device.instance,
            object: i.object,
            objectName: i.name,
            mac: event.sourceMac,
            net: event.sourceNetwork,
          );
        case BacnetUnconfirmedService.textMessage:
          final t = decodeTextMessage(event.data);
          return TextMessageEvent(
            sourceDeviceId: t.source.instance,
            message: t.message,
            urgent: t.urgent,
            classNumber: t.classNumber,
            classText: t.classText,
          );
        case BacnetUnconfirmedService.whoAmI:
          final w = decodeWhoAmI(event.data);
          return WhoAmIEvent(
            vendorId: w.vendorId,
            modelName: w.modelName,
            serialNumber: w.serialNumber,
            mac: event.sourceMac,
            net: event.sourceNetwork,
            adr: event.sourceAdr,
          );
        case BacnetUnconfirmedService.youAre:
          final y = decodeYouAre(event.data);
          return YouAreEvent(
            vendorId: y.vendorId,
            modelName: y.modelName,
            serialNumber: y.serialNumber,
            deviceId: y.deviceId,
            macAddress: y.macAddress,
            mac: event.sourceMac,
            net: event.sourceNetwork,
            adr: event.sourceAdr,
          );
        case BacnetUnconfirmedService.writeGroup:
          final g = decodeWriteGroup(event.data);
          return WriteGroupEvent(
            groupNumber: g.groupNumber,
            writePriority: g.writePriority,
            changes: g.changes,
            inhibitDelay: g.inhibitDelay,
            mac: event.sourceMac,
            net: event.sourceNetwork,
          );
        case BacnetUnconfirmedService.privateTransfer:
          final p = decodePrivateTransfer(event.data);
          return PrivateTransferEvent(
            vendorId: p.vendorId,
            serviceNumber: p.serviceNumber,
            parameters: p.parameters,
            mac: event.sourceMac,
            net: event.sourceNetwork,
          );
      }
    } on BacnetDecodeException catch (e) {
      _log(BacnetLogLevel.warning, 'malformed service ${event.service}: $e');
    }
    return _serviceEvent(event, confirmed: false);
  }

  void _networkMessage(NativeEvent event) {
    try {
      _emit(
        NetworkMessageEvent(
          message: BacnetNetworkMessage.decode(
            BacnetNetworkMessageType(event.service),
            event.data,
            vendorId: event.a,
          ),
          mac: event.sourceMac,
          net: event.sourceNetwork,
          adr: event.sourceAdr,
          destinationNetwork: event.b,
        ),
      );
    } on BacnetDecodeException catch (e) {
      _log(BacnetLogLevel.warning, 'network message: $e');
    }
  }

  /// The typed event notification, or the raw request when it is
  /// malformed.
  BacnetEvent _eventNotification(NativeEvent event, {required bool confirmed}) {
    try {
      return decodeEventNotification(
        event.data,
        confirmed: confirmed,
        mac: event.sourceMac,
        net: event.sourceNetwork,
      );
    } on BacnetDecodeException catch (e) {
      _log(BacnetLogLevel.warning, 'malformed event notification: $e');
      return _serviceEvent(event, confirmed: confirmed);
    }
  }

  BacnetEvent _auditNotification(NativeEvent event, {required bool confirmed}) {
    try {
      return AuditNotificationEvent(
        notification: decodeAuditNotification(event.data),
        confirmed: confirmed,
        mac: event.sourceMac,
        net: event.sourceNetwork,
      );
    } on BacnetDecodeException catch (e) {
      _log(BacnetLogLevel.warning, 'malformed audit notification: $e');
      return _serviceEvent(event, confirmed: confirmed);
    }
  }

  /// The typed event of a confirmed request that changed the local server,
  /// or the raw request when it is malformed.
  BacnetEvent _serviceRequestEvent(NativeEvent event) {
    try {
      switch (event.service) {
        case BacnetConfirmedService.acknowledgeAlarm:
          final ack = decodeAcknowledgeAlarm(event.data);
          return AlarmAcknowledgedEvent(
            processId: ack.processId,
            object: ack.object,
            eventState: ack.eventState,
            timeStamp: ack.timeStamp,
            source: ack.source,
            timeOfAcknowledgment: ack.timeOfAcknowledgment,
            mac: event.sourceMac,
            net: event.sourceNetwork,
          );
        case BacnetConfirmedService.deviceCommunicationControl:
          final dcc = decodeDeviceCommunicationControl(event.data);
          return CommunicationControlEvent(
            state: dcc.state,
            duration: dcc.duration,
            mac: event.sourceMac,
            net: event.sourceNetwork,
          );
        case BacnetConfirmedService.reinitializeDevice:
          return ReinitializeDeviceEvent(
            state: decodeReinitializeDevice(event.data).state,
            mac: event.sourceMac,
            net: event.sourceNetwork,
          );
        case BacnetConfirmedService.atomicWriteFile:
          final write = decodeAtomicWriteFile(event.data);
          if (write.data case final data?) {
            return FileWriteEvent(
              instance: write.file.instance,
              start: write.start,
              data: data,
              mac: event.sourceMac,
              net: event.sourceNetwork,
            );
          }
        case BacnetConfirmedService.addListElement ||
            BacnetConfirmedService.removeListElement:
          final list = decodeListElements(event.data);
          return ListElementEvent(
            object: list.object,
            propertyId: list.propertyId,
            arrayIndex: list.arrayIndex,
            added: event.service == BacnetConfirmedService.addListElement,
            elements: list.elements,
            mac: event.sourceMac,
            net: event.sourceNetwork,
          );
      }
    } on BacnetDecodeException catch (e) {
      _log(BacnetLogLevel.warning, 'malformed service ${event.service}: $e');
    }
    return _serviceEvent(event, confirmed: true);
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
      internal: event.hasFlag(BP_FLAG_INTERNAL),
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

  /// One [CovNotificationEvent] per object of a COVNotificationMultiple.
  void _emitCovMultiple(Uint8List data, {required bool confirmed}) {
    try {
      final cov = decodeCovNotificationMultiple(data);
      final received = DateTime.now().toIso8601String();
      for (final notification in cov.notifications) {
        _emit(
          CovNotificationEvent(
            objectType: notification.object.type,
            instance: notification.object.instance,
            timestamp: received,
            deviceId: cov.initiatingDeviceId,
            subscriberProcessId: cov.subscriberProcessId,
            timeRemaining: cov.timeRemaining,
            values: {
              for (final v in notification.values) v.propertyId: v.value,
            },
            confirmed: confirmed,
            notificationTime: cov.timestamp,
            changeTimes: notification.changeTimes,
          ),
        );
      }
    } on BacnetDecodeException catch (e) {
      _log(BacnetLogLevel.warning, 'malformed COV notification: $e');
    }
  }
}
