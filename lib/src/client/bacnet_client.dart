/// @docImport '../server/bacnet_server.dart';
/// @docImport '../utilities/property_monitor.dart';
library;

import 'dart:async';
import 'dart:typed_data';

import '../codec/log_records.dart';
import '../codec/requests.dart';
import '../codec/responses.dart';
import '../codec/values.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../constants/services.dart';
import '../core/bacnet_config.dart';
import '../core/exceptions.dart';
import '../core/logger.dart';
import '../core/types.dart';
import '../models/bacnet_object.dart';
import '../models/bacnet_stats.dart';
import '../models/events.dart';
import '../models/rpm_models.dart';
import '../models/trend_log_data.dart';
import '../models/wpm_models.dart';
import '../native/bacnet_system.dart';
import '../native/protocol.dart';

/// BACnet client for communication with BACnet devices.
///
/// Requests are executed by a worker isolate that owns the native stack.
/// The worker queues requests per device and keeps at most
/// [BacnetConfig.maxConcurrentRequests] transactions (and
/// [BacnetConfig.maxConcurrentRequestsPerDevice] per device) on the wire, so
/// thousands of concurrent calls can be issued safely:
///
/// ```dart
/// final client = BacnetClient(config: const BacnetConfig(interface: 'eth0'));
/// await client.start();
///
/// // 10 000 reads, at most 200 in flight, 4 per device
/// final values = await Future.wait([
///   for (final point in points)
///     client.readProperty(point.device, point.type, point.instance,
///         BacnetPropertyId.presentValue),
/// ]);
/// ```
///
/// Unknown device addresses are resolved automatically with a targeted
/// Who-Is; failures are reported with typed exceptions
/// ([BacnetTimeoutException], [BacnetProtocolException],
/// [BacnetRejectException], [BacnetAbortException],
/// [BacnetDeviceNotFoundException], [BacnetQueueFullException]).
class BacnetClient {
  /// Creates a BACnet client.
  ///
  /// [logger] overrides [BacnetConfig.logger].
  BacnetClient({BacnetLogger? logger, BacnetConfig? config})
    : _config = config ?? const BacnetConfig() {
    if (logger != null) {
      _system.setLogger(logger);
    }
  }

  final BacnetConfig _config;
  final BacnetSystem _system = BacnetSystem.instance;
  bool _started = false;
  int _nextProcessId = 1;

  /// Configuration of this client.
  BacnetConfig get config => _config;

  /// Stream of all unsolicited events (I-Am, COV notifications, server
  /// writes, logs and errors).
  Stream<BacnetEvent> get events => _system.events;

  /// I-Am announcements.
  Stream<IAmEvent> get iAmEvents => events.whereType<IAmEvent>();

  /// Change-of-Value notifications.
  Stream<CovNotificationEvent> get covEvents =>
      events.whereType<CovNotificationEvent>();

  /// Version of the native engine and bacnet-stack, once started.
  String? get nativeVersion => _system.nativeVersion;

  /// Logs a message using the configured logger.
  void log(
    BacnetLogLevel level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    _system.log(level, message, error, stackTrace);
  }

  /// Starts the BACnet stack (shared with [BacnetServer] instances).
  ///
  /// [interface] and [port] override the values of [config].
  Future<void> start({String? interface, int? port}) async {
    if (_started) return;
    await _system.start(_config.copyWith(interface: interface, port: port));
    _started = true;
  }

  /// Sends a Who-Is to discover devices.
  ///
  /// [lowLimit] and [highLimit] limit the device instance range (-1 for no
  /// limit). [network] selects the broadcast: 0xFFFF global (default), 0
  /// local network only, or a remote network number. Listen to [iAmEvents]
  /// for the answers.
  Future<void> sendWhoIs({
    int lowLimit = -1,
    int highLimit = -1,
    int network = 0xFFFF,
  }) {
    return _system.call<void>(
      (id) => UnconfirmedRequestCommand(
        id,
        service: BacnetUnconfirmedService.whoIs,
        payload: encodeWhoIs(
          lowLimit: lowLimit < 0 ? null : lowLimit,
          highLimit: highLimit < 0 ? null : highLimit,
        ),
        network: network,
      ),
    );
  }

  /// Reads a property of an object.
  ///
  /// Returns the decoded value: [double] (REAL), [int] (Unsigned, Signed,
  /// Enumerated), [bool], [String], [BacnetObject] (object identifiers),
  /// [BacnetBitString], [BacnetDate], [BacnetTime], [Uint8List] (octet
  /// strings), `null`, or a [List] for arrays and lists.
  ///
  /// ```dart
  /// final value = await client.readProperty(
  ///   1234,
  ///   BacnetObjectType.analogInput,
  ///   1,
  ///   BacnetPropertyId.presentValue,
  /// );
  /// ```
  Future<dynamic> readProperty(
    int deviceId,
    int objectType,
    int instance,
    int propertyId, {
    int arrayIndex = -1,
    Duration? timeout,
  }) {
    return _system.confirmed(
      deviceId: deviceId,
      service: BacnetConfirmedService.readProperty,
      payload: encodeReadProperty(
        objectType,
        instance,
        propertyId,
        arrayIndex: arrayIndex,
      ),
      decoding: AckDecoding.readProperty,
      timeout: timeout,
    );
  }

  /// Reads multiple properties of multiple objects with
  /// ReadPropertyMultiple.
  ///
  /// Returns `'type:instance'` → property id → value; properties that could
  /// not be read map to a [BacnetError]. Requests whose answer does not fit
  /// into one APDU are split automatically.
  Future<Map<String, Map<int, dynamic>>> readMultiple(
    int deviceId,
    List<BacnetReadAccessSpecification> specs, {
    Duration? timeout,
  }) async {
    if (specs.isEmpty) return {};
    try {
      final result = await _system.confirmed(
        deviceId: deviceId,
        service: BacnetConfirmedService.readPropertyMultiple,
        payload: encodeReadPropertyMultiple(specs),
        decoding: AckDecoding.readPropertyMultiple,
        timeout: timeout,
      );
      return result! as Map<String, Map<int, dynamic>>;
    } on BacnetAbortException catch (e) {
      if (!e.isSegmentationNotSupported) rethrow;
      final halves = _splitSpecs(specs);
      if (halves == null) rethrow;
      final parts = await Future.wait([
        readMultiple(deviceId, halves.$1, timeout: timeout),
        readMultiple(deviceId, halves.$2, timeout: timeout),
      ]);
      final merged = <String, Map<int, dynamic>>{};
      for (final part in parts) {
        for (final entry in part.entries) {
          (merged[entry.key] ??= <int, dynamic>{}).addAll(entry.value);
        }
      }
      return merged;
    }
  }

  static (
    List<BacnetReadAccessSpecification>,
    List<BacnetReadAccessSpecification>,
  )?
  _splitSpecs(List<BacnetReadAccessSpecification> specs) {
    final flat = [
      for (final spec in specs)
        for (final property in spec.properties)
          (spec.objectIdentifier, property),
    ];
    if (flat.length <= 1) return null;
    List<BacnetReadAccessSpecification> group(
      Iterable<(BacnetObject, BacnetPropertyReference)> items,
    ) {
      final result = <BacnetReadAccessSpecification>[];
      for (final (object, property) in items) {
        if (result.isNotEmpty && result.last.objectIdentifier == object) {
          result[result.length - 1] = result.last.copyWith(
            properties: [...result.last.properties, property],
          );
        } else {
          result.add(
            BacnetReadAccessSpecification(
              objectIdentifier: object,
              properties: [property],
            ),
          );
        }
      }
      return result;
    }

    final middle = flat.length ~/ 2;
    return (group(flat.take(middle)), group(flat.skip(middle)));
  }

  /// Writes a property value.
  ///
  /// The BACnet datatype is inferred from the object type, the property
  /// and the Dart value (REAL for analog present values, ENUMERATED for
  /// binary ones, UNSIGNED for multi-state ones, ...). Use [tag] (see
  /// [BacnetApplicationTag]) or a [BacnetValue] to force it. `null` writes
  /// NULL, which relinquishes the given [priority].
  ///
  /// ```dart
  /// await client.writeProperty(
  ///   1234,
  ///   BacnetObjectType.analogOutput,
  ///   1,
  ///   BacnetPropertyId.presentValue,
  ///   75.5,
  ///   priority: 8,
  /// );
  /// ```
  Future<void> writeProperty(
    int deviceId,
    int objectType,
    int instance,
    int propertyId,
    dynamic value, {
    int priority = 16,
    int? tag,
    int arrayIndex = -1,
    Duration? timeout,
  }) async {
    await _system.confirmed(
      deviceId: deviceId,
      service: BacnetConfirmedService.writeProperty,
      payload: encodeWriteProperty(
        objectType,
        instance,
        propertyId,
        value,
        tag: tag,
        arrayIndex: arrayIndex,
        priority: priority,
      ),
      timeout: timeout,
    );
  }

  /// Writes multiple properties of multiple objects with
  /// WritePropertyMultiple.
  Future<void> writeMultiple(
    int deviceId,
    List<BacnetWriteAccessSpecification> specs, {
    Duration? timeout,
  }) async {
    if (specs.isEmpty) return;
    await _system.confirmed(
      deviceId: deviceId,
      service: BacnetConfirmedService.writePropertyMultiple,
      payload: encodeWritePropertyMultiple(specs),
      timeout: timeout,
    );
  }

  /// Registers this client as a Foreign Device with a BBMD.
  ///
  /// The registration is renewed automatically before [ttl] expires.
  Future<void> registerForeignDevice(
    String ip, {
    int port = 47808,
    int ttl = 120,
  }) {
    return _system.call<void>(
      (id) => RegisterForeignDeviceCommand(id, host: ip, port: port, ttl: ttl),
    );
  }

  /// Reads the object list of a device.
  ///
  /// Reads the whole Object_List at once and falls back to reading it
  /// element by element when the device cannot send it in one APDU.
  /// [endDeviceId] is ignored (kept for compatibility).
  Future<List<BacnetObject>> scanDevice(
    int deviceId, [
    int? endDeviceId,
  ]) async {
    try {
      final value = await readProperty(
        deviceId,
        BacnetObjectType.device,
        deviceId,
        BacnetPropertyId.objectList,
      );
      return _objects(value);
    } on BacnetAbortException catch (e) {
      if (!e.isSegmentationNotSupported) rethrow;
    } on BacnetProtocolException {
      // some devices refuse to return the whole array
    }
    final count = await readProperty(
      deviceId,
      BacnetObjectType.device,
      deviceId,
      BacnetPropertyId.objectList,
      arrayIndex: 0,
    );
    if (count is! int || count <= 0) return const [];
    final elements = await Future.wait([
      for (var i = 1; i <= count; i++)
        readProperty(
          deviceId,
          BacnetObjectType.device,
          deviceId,
          BacnetPropertyId.objectList,
          arrayIndex: i,
        ),
    ]);
    return _objects(elements);
  }

  static List<BacnetObject> _objects(Object? value) => switch (value) {
    final BacnetObject object => [object],
    final List<Object?> list => list.whereType<BacnetObject>().toList(),
    _ => const [],
  };

  /// Adds (or replaces) a static device address binding.
  ///
  /// Not needed for devices that answer Who-Is: their address is learned
  /// automatically. [network] and [adr] address devices behind a router.
  Future<void> addDeviceBinding(
    int deviceId,
    String ip, {
    int port = 47808,
    int network = 0,
    List<int> adr = const [],
    int maxApdu = 1476,
  }) {
    return _system.call<void>(
      (id) => BindDeviceCommand(
        id,
        deviceId: deviceId,
        host: ip,
        port: port,
        network: network,
        adr: adr,
        maxApdu: maxApdu,
      ),
    );
  }

  /// Removes the address binding of a device.
  Future<void> removeDeviceBinding(int deviceId) =>
      _system.call<void>((id) => UnbindDeviceCommand(id, deviceId));

  /// Returns true when the address of [deviceId] is known.
  Future<bool> isDeviceBound(int deviceId) async =>
      await _system.call<Object?>((id) => DeviceBindingCommand(id, deviceId)) !=
      null;

  /// Allocates a subscriber process identifier for COV subscriptions.
  int allocateProcessId() {
    final id = _nextProcessId;
    _nextProcessId = _nextProcessId >= 0x3FFFFF ? 1 : _nextProcessId + 1;
    return id;
  }

  /// Subscribes to Change-of-Value notifications of an object.
  ///
  /// Completes when the device acknowledged the subscription. Present
  /// value subscriptions use SubscribeCOV, other properties
  /// SubscribeCOVProperty. Subscriptions expire after [lifetime] and must be
  /// renewed ([PropertyMonitor] does this automatically). Listen to
  /// [covEvents] for the notifications.
  Future<void> subscribeCOV(
    int deviceId,
    int objectType,
    int instance, {
    int propId = BacnetPropertyId.presentValue,
    int processId = 1,
    Duration lifetime = const Duration(minutes: 5),
    bool confirmed = false,
    double? covIncrement,
    Duration? timeout,
  }) async {
    final lifetimeSeconds = lifetime.inSeconds;
    final usePropertyService =
        propId != BacnetPropertyId.presentValue || covIncrement != null;
    await _system.confirmed(
      deviceId: deviceId,
      service: usePropertyService
          ? BacnetConfirmedService.subscribeCovProperty
          : BacnetConfirmedService.subscribeCov,
      payload: usePropertyService
          ? encodeSubscribeCovProperty(
              subscriberProcessId: processId,
              objectType: objectType,
              instance: instance,
              propertyId: propId,
              confirmed: confirmed,
              lifetime: lifetimeSeconds,
              covIncrement: covIncrement,
            )
          : encodeSubscribeCov(
              subscriberProcessId: processId,
              objectType: objectType,
              instance: instance,
              confirmed: confirmed,
              lifetime: lifetimeSeconds,
            ),
      timeout: timeout,
    );
  }

  /// Cancels a COV subscription created with [subscribeCOV].
  Future<void> unsubscribeCOV(
    int deviceId,
    int objectType,
    int instance, {
    int propId = BacnetPropertyId.presentValue,
    int processId = 1,
    Duration? timeout,
  }) async {
    final usePropertyService = propId != BacnetPropertyId.presentValue;
    await _system.confirmed(
      deviceId: deviceId,
      service: usePropertyService
          ? BacnetConfirmedService.subscribeCovProperty
          : BacnetConfirmedService.subscribeCov,
      payload: usePropertyService
          ? encodeSubscribeCovProperty(
              subscriberProcessId: processId,
              objectType: objectType,
              instance: instance,
              propertyId: propId,
              cancel: true,
            )
          : encodeSubscribeCov(
              subscriberProcessId: processId,
              objectType: objectType,
              instance: instance,
              cancel: true,
            ),
      timeout: timeout,
    );
  }

  /// Reads a range of a list property with ReadRange.
  Future<ReadRangeResult> readRange(
    int deviceId,
    int objectType,
    int instance,
    int propertyId, {
    ReadRangeType type = ReadRangeType.all,
    Object? reference,
    int count = 0,
    int arrayIndex = -1,
    Duration? timeout,
  }) async {
    final result = await _system.confirmed(
      deviceId: deviceId,
      service: BacnetConfirmedService.readRange,
      payload: encodeReadRange(
        objectType,
        instance,
        propertyId,
        arrayIndex: arrayIndex,
        type: type,
        reference: reference,
        count: count,
      ),
      decoding: AckDecoding.readRange,
      timeout: timeout,
    );
    return result! as ReadRangeResult;
  }

  /// Reads records of a Trend Log object.
  ///
  /// By default reads the newest [count] records (by position, backwards
  /// from the end of the buffer). Pass [fromSequenceNumber] to read forward
  /// from a sequence number (incremental collection).
  Future<TrendLogData> getTrendLog(
    int deviceId,
    int instance, {
    int logBufferPropId = BacnetPropertyId.logBuffer,
    int count = 100,
    int? fromSequenceNumber,
    Duration? timeout,
  }) async {
    final ReadRangeResult result;
    if (fromSequenceNumber != null) {
      result = await readRange(
        deviceId,
        BacnetObjectType.trendLog,
        instance,
        logBufferPropId,
        type: ReadRangeType.bySequenceNumber,
        reference: fromSequenceNumber,
        count: count,
        timeout: timeout,
      );
    } else {
      final recordCount = await readProperty(
        deviceId,
        BacnetObjectType.trendLog,
        instance,
        BacnetPropertyId.recordCount,
        timeout: timeout,
      );
      final total = recordCount is int ? recordCount : 0;
      if (total == 0) {
        return const TrendLogData(itemCount: 0, totalRecords: 0);
      }
      result = await readRange(
        deviceId,
        BacnetObjectType.trendLog,
        instance,
        logBufferPropId,
        type: ReadRangeType.byPosition,
        reference: total,
        count: -count,
        timeout: timeout,
      );
    }
    final entries = decodeLogRecords(result.items);
    final first = result.firstSequenceNumber;
    return TrendLogData(
      itemCount: result.itemCount,
      totalRecords: first != null && result.itemCount > 0
          ? first + result.itemCount - 1
          : result.itemCount,
      entries: entries,
    );
  }

  /// Sends a (UTC)TimeSynchronization to a device or as broadcast.
  Future<void> timeSynchronization(
    DateTime time, {
    bool utc = false,
    int? deviceId,
  }) {
    return _system.call<void>(
      (id) => UnconfirmedRequestCommand(
        id,
        service: utc
            ? BacnetUnconfirmedService.utcTimeSynchronization
            : BacnetUnconfirmedService.timeSynchronization,
        payload: encodeTimeSynchronization(utc ? time.toUtc() : time),
        deviceId: deviceId,
      ),
    );
  }

  /// Sends any confirmed service with pre-encoded service data and returns
  /// the raw service ACK data (empty for a Simple-ACK).
  Future<Uint8List> sendConfirmedRaw(
    int deviceId,
    int service,
    Uint8List serviceData, {
    Duration? timeout,
  }) async {
    final result = await _system.confirmed(
      deviceId: deviceId,
      service: service,
      payload: serviceData,
      decoding: AckDecoding.raw,
      timeout: timeout,
    );
    return result is Uint8List ? result : Uint8List(0);
  }

  /// Returns runtime statistics of the engine.
  Future<BacnetStats> stats() => _system.stats();

  /// Releases the stack (stopped when no client or server uses it).
  Future<void> close() async {
    if (!_started) return;
    _started = false;
    await _system.release();
  }

  /// Disposes of the client and releases resources.
  ///
  /// The client cannot be used after calling dispose. Prefer [close] to
  /// await the shutdown.
  void dispose() {
    unawaited(close());
  }
}

extension on Stream<BacnetEvent> {
  Stream<T> whereType<T>() => where((event) => event is T).cast<T>();
}
