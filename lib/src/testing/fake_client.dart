import 'dart:async';
import 'dart:typed_data';

import '../client/bacnet_client.dart';
import '../client/read_specs.dart';
import '../codec/requests.dart';
import '../codec/responses.dart';
import '../constants/engineering_units.dart';
import '../constants/enumerations.dart';
import '../constants/errors.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../constants/services.dart';
import '../core/bacnet_config.dart';
import '../core/cancel_token.dart';
import '../core/exceptions.dart';
import '../core/types.dart';
import '../models/bacnet_stats.dart';
import '../models/bacnet_value.dart';
import '../models/events.dart';
import '../models/rpm_models.dart';
import '../models/trend_log_data.dart';
import '../models/wpm_models.dart';

/// A request received by a [FakeBacnetClient], for assertions in tests.
final class FakeBacnetRequest {
  /// Creates a request record.
  const FakeBacnetRequest(
    this.service, {
    this.deviceId,
    this.object,
    this.propertyId,
    this.value,
    this.priority,
    this.time,
    this.address,
  });

  /// Client method, e.g. `readProperty`, `writeProperty`, `subscribeCOV`.
  final String service;

  /// Target device.
  final int? deviceId;

  /// Target object.
  final BacnetObject? object;

  /// Target property.
  final BacnetPropertyId? propertyId;

  /// Written value.
  final BacnetValue? value;

  /// Write priority.
  final int? priority;

  /// Time sent with `timeSynchronization`.
  final DateTime? time;

  /// BBMD address (`host:port`) of `registerForeignDevice`.
  final String? address;

  @override
  String toString() =>
      'FakeBacnetRequest($service, device: $deviceId, object: $object, '
      'property: $propertyId, value: $value)';
}

/// An object of a [FakeBacnetDevice].
final class FakeBacnetObject {
  FakeBacnetObject._(this.device, this.type, this.instance, this.commandable);

  /// The device hosting the object.
  final FakeBacnetDevice device;

  /// Object type.
  final BacnetObjectType type;

  /// Object instance.
  final int instance;

  /// Whether the present value is commanded through a priority array.
  final bool commandable;

  /// Property values.
  final Map<BacnetPropertyId, BacnetValue> properties = {};

  final List<BacnetValue> _priorityArray = List.filled(16, const BacnetNull());

  /// Trend Log records returned by [FakeBacnetClient.getTrendLog].
  final List<TrendLogEntry> records = [];

  /// The object identifier.
  BacnetObject get identifier => BacnetObject(type: type, instance: instance);

  /// Value of [property], or null.
  BacnetValue? operator [](BacnetPropertyId property) => properties[property];

  /// Sets [property] like a change in the field (not a client write) and
  /// notifies COV subscribers.
  void operator []=(BacnetPropertyId property, BacnetValue value) {
    properties[property] = value;
    device._changed(this, property);
  }

  /// Applies a client write with WriteProperty semantics.
  void _write(BacnetPropertyId property, BacnetValue value, int priority) {
    if (property == BacnetPropertyId.presentValue && commandable) {
      _priorityArray[(priority.clamp(1, 16)) - 1] = value;
      _publishPriorityArray();
      properties[property] = _priorityArray.firstWhere(
        (v) => v is! BacnetNull,
        orElse: () =>
            properties[BacnetPropertyId.relinquishDefault] ??
            const BacnetNull(),
      );
    } else {
      properties[property] = value;
    }
    device._changed(this, property);
  }

  void _publishPriorityArray() {
    properties[BacnetPropertyId.priorityArray] = BacnetList(
      List.unmodifiable(_priorityArray),
    );
  }

  /// Present value of a new object without one.
  static BacnetValue _defaultPresentValue(BacnetObjectType type) =>
      switch (type) {
        BacnetObjectType.analogInput ||
        BacnetObjectType.analogOutput ||
        BacnetObjectType.analogValue => const BacnetReal(0),
        BacnetObjectType.binaryInput ||
        BacnetObjectType.binaryOutput ||
        BacnetObjectType.binaryValue => const BacnetEnumerated(
          BacnetBinaryPV.inactive,
        ),
        BacnetObjectType.multiStateInput ||
        BacnetObjectType.multiStateOutput ||
        BacnetObjectType.multiStateValue => const BacnetUnsigned(1),
        BacnetObjectType.integerValue => const BacnetSigned(0),
        BacnetObjectType.positiveIntegerValue => const BacnetUnsigned(0),
        BacnetObjectType.characterStringValue => const BacnetCharacterString(
          '',
        ),
        _ => const BacnetNull(),
      };
}

/// An in-memory BACnet device for [FakeBacnetClient].
///
/// ```dart
/// final device = FakeBacnetDevice(1234, name: 'AHU-1')
///   ..addObject(
///     BacnetObjectType.analogInput,
///     1,
///     name: 'Supply Air Temperature',
///     presentValue: const BacnetReal(21.5),
///     units: BacnetEngineeringUnits.degreesCelsius,
///   );
/// final client = FakeBacnetClient(devices: [device]);
/// ```
final class FakeBacnetDevice {
  /// Creates a device with its Device object.
  FakeBacnetDevice(
    this.deviceId, {
    String? name,
    this.vendorId = 0,
    this.maxApdu = 1476,
    this.segmentation = BacnetSegmentation.both,
    String vendorName = 'bacnet_plugin',
    String modelName = 'FakeBacnetDevice',
  }) {
    final device = addObject(
      BacnetObjectType.device,
      deviceId,
      name: name ?? 'Device $deviceId',
    );
    device.properties.addAll({
      BacnetPropertyId.vendorIdentifier: BacnetUnsigned(vendorId),
      BacnetPropertyId.vendorName: BacnetCharacterString(vendorName),
      BacnetPropertyId.modelName: BacnetCharacterString(modelName),
      BacnetPropertyId.maxApduLengthAccepted: BacnetUnsigned(maxApdu),
      BacnetPropertyId.segmentationSupported: BacnetEnumerated(segmentation),
      BacnetPropertyId.protocolVersion: const BacnetUnsigned(1),
      BacnetPropertyId.protocolRevision: const BacnetUnsigned(22),
    });
  }

  /// Device instance.
  final int deviceId;

  /// Vendor identifier announced in I-Am.
  final int vendorId;

  /// Maximum APDU announced in I-Am.
  final int maxApdu;

  /// Segmentation support announced in I-Am.
  final BacnetSegmentation segmentation;

  /// While false, requests to the device time out and it ignores Who-Is.
  bool online = true;

  /// Extra response time of this device.
  Duration latency = Duration.zero;

  final Map<(BacnetObjectType, int), FakeBacnetObject> _objects = {};
  final List<void Function(FakeBacnetObject, BacnetPropertyId)> _listeners = [];

  /// Objects of the device, the Device object first.
  Iterable<FakeBacnetObject> get objects => _objects.values;

  /// Adds an object. Outputs are commandable unless [commandable] says
  /// otherwise; their [presentValue] becomes the relinquish default. Without
  /// [presentValue] the object starts at 0, inactive or state 1.
  FakeBacnetObject addObject(
    BacnetObjectType type,
    int instance, {
    String? name,
    BacnetValue? presentValue,
    BacnetEngineeringUnits? units,
    bool? commandable,
    Map<BacnetPropertyId, BacnetValue> properties = const {},
  }) {
    final object = FakeBacnetObject._(
      this,
      type,
      instance,
      commandable ??
          (type == BacnetObjectType.analogOutput ||
              type == BacnetObjectType.binaryOutput ||
              type == BacnetObjectType.multiStateOutput),
    );
    object.properties.addAll({
      BacnetPropertyId.objectIdentifier: object.identifier,
      BacnetPropertyId.objectName: BacnetCharacterString(
        name ?? '${type.label} $instance',
      ),
      BacnetPropertyId.objectType: BacnetEnumerated(type),
      if (units != null) BacnetPropertyId.units: BacnetEnumerated(units),
      ...properties,
    });
    if (type != BacnetObjectType.device) {
      final value = presentValue ?? FakeBacnetObject._defaultPresentValue(type);
      object.properties[BacnetPropertyId.presentValue] = value;
      if (object.commandable) {
        object.properties[BacnetPropertyId.relinquishDefault] = value;
        object._publishPriorityArray();
      }
    }
    _objects[(type, instance)] = object;
    return object;
  }

  /// The object [type]:[instance], or null.
  FakeBacnetObject? object(BacnetObjectType type, int instance) =>
      _objects[(type, instance)];

  void _changed(FakeBacnetObject object, BacnetPropertyId property) {
    for (final listener in List.of(_listeners)) {
      listener(object, property);
    }
  }

  BacnetValue _read(BacnetObjectType type, int instance, BacnetPropertyId id) {
    final object = _objects[(type, instance)];
    if (object == null) {
      throw _error(BacnetErrorClass.object, BacnetErrorCode.unknownObject);
    }
    if (type == BacnetObjectType.device && id == BacnetPropertyId.objectList) {
      return BacnetList([for (final o in _objects.values) o.identifier]);
    }
    return object.properties[id] ??
        (throw _error(
          BacnetErrorClass.property,
          BacnetErrorCode.unknownProperty,
        ));
  }

  BacnetProtocolException _error(BacnetErrorClass c, BacnetErrorCode e) =>
      BacnetProtocolException(
        'device $deviceId returned an error',
        errorClass: c,
        errorCode: e,
      );
}

typedef _Subscription = ({
  int deviceId,
  BacnetObjectType type,
  int instance,
  BacnetPropertyId property,
  int processId,
  bool confirmed,
});

/// A [BacnetClient] backed by in-memory [FakeBacnetDevice]s, for testing
/// applications without a network or the native stack.
///
/// It discovers devices (Who-Is/I-Am), reads and writes properties with the
/// errors real devices return, commands outputs through a priority array,
/// sends COV notifications for subscribed properties and can simulate
/// latency and offline devices. Every request is recorded in [requests].
///
/// ```dart
/// final ahu = FakeBacnetDevice(1234)
///   ..addObject(BacnetObjectType.analogValue, 1,
///       presentValue: const BacnetReal(21));
/// final client = FakeBacnetClient(devices: [ahu]);
/// await client.start();
///
/// final monitor = PropertyMonitor(client);
/// final updates = monitor.monitorPresentValue(
///   1234,
///   const BacnetObject(type: BacnetObjectType.analogValue, instance: 1),
/// );
/// ahu.object(BacnetObjectType.analogValue, 1)![BacnetPropertyId.presentValue] =
///     const BacnetReal(22.5); // delivered as a COV notification
/// ```
class FakeBacnetClient implements BacnetClient {
  /// Creates a client serving [devices].
  FakeBacnetClient({
    Iterable<FakeBacnetDevice> devices = const [],
    this.latency = Duration.zero,
    BacnetConfig config = const BacnetConfig(),
  }) : _config = config {
    devices.forEach(addDevice);
  }

  final BacnetConfig _config;
  final Map<int, FakeBacnetDevice> _devices = {};
  final Set<int> _bound = {};
  final List<_Subscription> _subscriptions = [];
  final StreamController<BacnetEvent> _events =
      StreamController<BacnetEvent>.broadcast();
  bool _started = false;
  int _nextProcessId = 1;
  int _completed = 0;
  int _failed = 0;
  int _timeouts = 0;

  /// Response time of every request.
  Duration latency;

  /// Requests received, oldest first.
  final List<FakeBacnetRequest> requests = [];

  /// Devices served by this client.
  Map<int, FakeBacnetDevice> get devices => Map.unmodifiable(_devices);

  /// Adds a device; it answers Who-Is and requests.
  void addDevice(FakeBacnetDevice device) {
    _devices[device.deviceId] = device;
    device._listeners.add(
      (object, property) => _notify(device, object, property),
    );
  }

  @override
  BacnetConfig get config => _config;

  @override
  Stream<BacnetEvent> get events => _events.stream;

  @override
  Stream<IAmEvent> get iAmEvents =>
      events.where((e) => e is IAmEvent).cast<IAmEvent>();

  @override
  Stream<CovNotificationEvent> get covEvents => events
      .where((e) => e is CovNotificationEvent)
      .cast<CovNotificationEvent>();

  @override
  String? get nativeVersion => _started ? 'fake' : null;

  @override
  void log(
    BacnetLogLevel level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    _config.logger.log(level, message, error, stackTrace);
  }

  @override
  Future<void> start({String? interface, int? port}) async {
    _started = true;
  }

  @override
  Future<void> close() async {
    _started = false;
  }

  @override
  void dispose() => _started = false;

  @override
  int allocateProcessId() {
    final id = _nextProcessId;
    _nextProcessId = _nextProcessId >= 0x3FFFFF ? 1 : _nextProcessId + 1;
    return id;
  }

  @override
  Future<void> sendWhoIs({
    int lowLimit = -1,
    int highLimit = -1,
    int network = 0xFFFF,
  }) async {
    _checkStarted();
    requests.add(const FakeBacnetRequest('sendWhoIs'));
    for (final device in _devices.values) {
      final id = device.deviceId;
      if (!device.online ||
          (lowLimit >= 0 && id < lowLimit) ||
          (highLimit >= 0 && id > highLimit)) {
        continue;
      }
      _bound.add(id);
      unawaited(
        Future<void>.delayed(latency + device.latency, () {
          if (_events.isClosed) return;
          _events.add(
            IAmEvent(
              deviceId: id,
              net: 0,
              mac: [10, 0, (id >> 8) & 0xFF, id & 0xFF, 0xBA, 0xC0],
              len: 0,
              maxApdu: device.maxApdu,
              vendorId: device.vendorId,
              segmentation: device.segmentation,
            ),
          );
        }),
      );
    }
  }

  @override
  Future<BacnetValue> readProperty(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId, {
    int arrayIndex = -1,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(
      FakeBacnetRequest(
        'readProperty',
        deviceId: deviceId,
        object: BacnetObject(type: objectType, instance: instance),
        propertyId: propertyId,
      ),
    );
    return _request(deviceId, cancelToken, (device) {
      final value = device._read(objectType, instance, propertyId);
      if (arrayIndex < 0) return value;
      if (value is! BacnetList) {
        throw device._error(
          BacnetErrorClass.property,
          BacnetErrorCode.propertyIsNotAnArray,
        );
      }
      if (arrayIndex == 0) return BacnetUnsigned(value.length);
      if (arrayIndex > value.length) {
        throw device._error(
          BacnetErrorClass.property,
          BacnetErrorCode.invalidArrayIndex,
        );
      }
      return value[arrayIndex - 1];
    });
  }

  @override
  Future<Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>>
  readMultiple(
    int deviceId,
    List<BacnetReadAccessSpecification> specs, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(FakeBacnetRequest('readMultiple', deviceId: deviceId));
    if (specs.isEmpty) return Future.value(const {});
    checkUniqueProperties(specs);
    return _request(deviceId, cancelToken, (device) {
      final result =
          <BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>{};
      for (final spec in specs) {
        final properties = result[spec.objectIdentifier] ??= {};
        for (final reference in spec.properties) {
          properties[reference.propertyIdentifier] = _readOrError(
            device,
            spec.objectIdentifier,
            reference.propertyIdentifier,
          );
        }
      }
      return result;
    });
  }

  static BacnetPropertyResult _readOrError(
    FakeBacnetDevice device,
    BacnetObject object,
    BacnetPropertyId property,
  ) {
    try {
      return device._read(object.type, object.instance, property);
    } on BacnetProtocolException catch (e) {
      return BacnetError(e.errorClass, e.errorCode);
    }
  }

  @override
  Future<void> writeProperty(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId,
    BacnetValue value, {
    int priority = 16,
    int arrayIndex = -1,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(
      FakeBacnetRequest(
        'writeProperty',
        deviceId: deviceId,
        object: BacnetObject(type: objectType, instance: instance),
        propertyId: propertyId,
        value: value,
        priority: priority,
      ),
    );
    return _request(deviceId, cancelToken, (device) {
      _write(device, objectType, instance, propertyId, value, priority);
    });
  }

  @override
  Future<void> writeMultiple(
    int deviceId,
    List<BacnetWriteAccessSpecification> specs, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(FakeBacnetRequest('writeMultiple', deviceId: deviceId));
    return _request(deviceId, cancelToken, (device) {
      for (final spec in specs) {
        for (final property in spec.listOfProperties) {
          _write(
            device,
            spec.objectIdentifier.type,
            spec.objectIdentifier.instance,
            property.propertyIdentifier,
            property.value,
            property.priority,
          );
        }
      }
    });
  }

  void _write(
    FakeBacnetDevice device,
    BacnetObjectType type,
    int instance,
    BacnetPropertyId property,
    BacnetValue value,
    int priority,
  ) {
    final object = device.object(type, instance);
    if (object == null) {
      throw device._error(
        BacnetErrorClass.object,
        BacnetErrorCode.unknownObject,
      );
    }
    if (!object.properties.containsKey(property)) {
      throw device._error(
        BacnetErrorClass.property,
        BacnetErrorCode.unknownProperty,
      );
    }
    object._write(property, value, priority);
  }

  @override
  Future<void> subscribeCOV(
    int deviceId,
    BacnetObjectType objectType,
    int instance, {
    BacnetPropertyId propId = BacnetPropertyId.presentValue,
    int processId = 1,
    Duration lifetime = const Duration(minutes: 5),
    bool confirmed = false,
    double? covIncrement,
    Duration? timeout,
  }) {
    requests.add(
      FakeBacnetRequest(
        'subscribeCOV',
        deviceId: deviceId,
        object: BacnetObject(type: objectType, instance: instance),
        propertyId: propId,
      ),
    );
    return _request(deviceId, null, (device) {
      device._read(objectType, instance, propId);
      _subscriptions
        ..removeWhere(
          (s) => _same(s, deviceId, objectType, instance, propId, processId),
        )
        ..add((
          deviceId: deviceId,
          type: objectType,
          instance: instance,
          property: propId,
          processId: processId,
          confirmed: confirmed,
        ));
    });
  }

  @override
  Future<void> unsubscribeCOV(
    int deviceId,
    BacnetObjectType objectType,
    int instance, {
    BacnetPropertyId propId = BacnetPropertyId.presentValue,
    int processId = 1,
    Duration? timeout,
  }) {
    requests.add(
      FakeBacnetRequest(
        'unsubscribeCOV',
        deviceId: deviceId,
        object: BacnetObject(type: objectType, instance: instance),
        propertyId: propId,
      ),
    );
    return _request(deviceId, null, (_) {
      _subscriptions.removeWhere(
        (s) => _same(s, deviceId, objectType, instance, propId, processId),
      );
    });
  }

  static bool _same(
    _Subscription s,
    int deviceId,
    BacnetObjectType type,
    int instance,
    BacnetPropertyId property,
    int processId,
  ) =>
      s.deviceId == deviceId &&
      s.type == type &&
      s.instance == instance &&
      s.property == property &&
      s.processId == processId;

  void _notify(
    FakeBacnetDevice device,
    FakeBacnetObject object,
    BacnetPropertyId property,
  ) {
    for (final s in _subscriptions) {
      if (s.deviceId != device.deviceId ||
          s.type != object.type ||
          s.instance != object.instance ||
          s.property != property) {
        continue;
      }
      final value = object.properties[property];
      if (value == null) continue;
      final values = <BacnetPropertyId, BacnetValue>{
        property: value,
        BacnetPropertyId.statusFlags:
            ?object.properties[BacnetPropertyId.statusFlags],
      };
      final event = CovNotificationEvent(
        objectType: object.type,
        instance: object.instance,
        timestamp: DateTime.now().toIso8601String(),
        deviceId: device.deviceId,
        subscriberProcessId: s.processId,
        values: values,
        confirmed: s.confirmed,
      );
      unawaited(
        Future<void>.delayed(latency + device.latency, () {
          if (!_events.isClosed) _events.add(event);
        }),
      );
    }
  }

  @override
  Future<List<BacnetObject>> scanDevice(
    int deviceId, {
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) async {
    final list = await readProperty(
      deviceId,
      BacnetObjectType.device,
      deviceId,
      BacnetPropertyId.objectList,
      cancelToken: cancelToken,
    );
    return list.asList.whereType<BacnetObject>().toList();
  }

  @override
  Future<TrendLogData> getTrendLog(
    int deviceId,
    int instance, {
    BacnetPropertyId logBufferPropId = BacnetPropertyId.logBuffer,
    int count = 100,
    int? fromSequenceNumber,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(
      FakeBacnetRequest(
        'getTrendLog',
        deviceId: deviceId,
        object: BacnetObject(
          type: BacnetObjectType.trendLog,
          instance: instance,
        ),
      ),
    );
    return _request(deviceId, cancelToken, (device) {
      final object = device.object(BacnetObjectType.trendLog, instance);
      if (object == null) {
        throw device._error(
          BacnetErrorClass.object,
          BacnetErrorCode.unknownObject,
        );
      }
      final records = object.records;
      final start = fromSequenceNumber != null
          ? (fromSequenceNumber - 1).clamp(0, records.length)
          : (records.length - count).clamp(0, records.length);
      final entries = records.skip(start).take(count).toList();
      return TrendLogData(
        itemCount: entries.length,
        totalRecords: records.length,
        entries: entries,
      );
    });
  }

  @override
  Future<ReadRangeResult> readRange(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId, {
    BacnetRange range = const BacnetRange.all(),
    int arrayIndex = -1,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => _unsupported(deviceId, 'readRange');

  @override
  Future<Uint8List> sendConfirmedRaw(
    int deviceId,
    BacnetConfirmedService service,
    Uint8List serviceData, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => _unsupported(deviceId, 'sendConfirmedRaw');

  Future<T> _unsupported<T>(int deviceId, String service) {
    requests.add(FakeBacnetRequest(service, deviceId: deviceId));
    return _request(
      deviceId,
      null,
      (_) => throw BacnetRejectException(
        'device $deviceId rejected the request',
        reason: BacnetRejectReason.unrecognizedService,
      ),
    );
  }

  @override
  Future<void> timeSynchronization(
    DateTime time, {
    bool utc = false,
    int? deviceId,
  }) async {
    _checkStarted();
    requests.add(
      FakeBacnetRequest('timeSynchronization', deviceId: deviceId, time: time),
    );
  }

  @override
  Future<void> registerForeignDevice(
    String ip, {
    int port = 47808,
    int ttl = 120,
  }) async {
    _checkStarted();
    requests.add(
      FakeBacnetRequest('registerForeignDevice', address: '$ip:$port'),
    );
  }

  @override
  Future<void> addDeviceBinding(
    int deviceId,
    String ip, {
    int port = 47808,
    int network = 0,
    List<int> adr = const [],
    int maxApdu = 1476,
  }) async {
    _checkStarted();
    _bound.add(deviceId);
  }

  @override
  Future<void> removeDeviceBinding(int deviceId) async {
    _bound.remove(deviceId);
  }

  @override
  Future<bool> isDeviceBound(int deviceId) async => _bound.contains(deviceId);

  @override
  Future<BacnetStats> stats() async => BacnetStats(
    queuedRequests: 0,
    inFlightRequests: 0,
    completedRequests: _completed,
    failedRequests: _failed,
    timeouts: _timeouts,
    packetsReceived: _completed,
    requestsSent: _completed + _failed,
    repliesDropped: 0,
    eventsDropped: 0,
    boundDevices: _bound.length,
    bindingDevices: 0,
    freeTransactions: 255,
    pollCalls: 0,
  );

  void _checkStarted() {
    if (!_started) throw const BacnetNotInitializedException();
  }

  /// Runs [answer] against the device after the simulated latency.
  Future<T> _request<T>(
    int deviceId,
    BacnetCancelToken? cancelToken,
    T Function(FakeBacnetDevice device) answer,
  ) {
    Future<T> run() async {
      _checkStarted();
      final device = _devices[deviceId];
      await Future<void>.delayed(latency + (device?.latency ?? Duration.zero));
      try {
        if (device == null) {
          throw BacnetDeviceNotFoundException(
            'device $deviceId did not answer Who-Is',
            deviceId: deviceId,
          );
        }
        if (!device.online) {
          _timeouts++;
          throw BacnetTimeoutException('device $deviceId did not answer');
        }
        _bound.add(deviceId);
        final result = answer(device);
        _completed++;
        return result;
      } on BacnetException {
        _failed++;
        rethrow;
      }
    }

    return cancelToken == null ? run() : cancelToken.guard(run());
  }
}
