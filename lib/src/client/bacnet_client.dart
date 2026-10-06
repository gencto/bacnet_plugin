/// @docImport '../server/bacnet_server.dart';
/// @docImport '../utilities/network_discovery.dart';
/// @docImport '../utilities/property_monitor.dart';
library;

import 'dart:async';
import 'dart:typed_data';

import '../codec/log_records.dart';
import '../codec/requests.dart';
import '../codec/responses.dart';
import '../constants/enumerations.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../constants/services.dart';
import '../core/bacnet_config.dart';
import '../core/cancel_token.dart';
import '../core/exceptions.dart';
import '../core/ip_address.dart';
import '../core/logger.dart';
import '../core/types.dart';
import '../models/alarms.dart';
import '../models/bacnet_property.dart';
import '../models/bacnet_stats.dart';
import '../models/bacnet_value.dart';
import '../models/channels.dart';
import '../models/complex_values.dart';
import '../models/cov_multiple.dart';
import '../models/events.dart';
import '../models/files.dart';
import '../models/network.dart';
import '../models/rpm_models.dart';
import '../models/trend_log_data.dart';
import '../models/wpm_models.dart';
import '../native/bacnet_system.dart';
import '../native/protocol.dart';
import 'read_coalescer.dart';
import 'read_specs.dart';

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
/// Request methods accept `background: true` for bulk work that should
/// wait behind interactive requests, and a [BacnetCancelToken] to drop
/// requests nobody waits for any more. Devices that stop answering are
/// considered offline after [BacnetConfig.offlineAfterTimeouts] timeouts
/// ([BacnetDeviceOfflineException]).
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
  late final ReadCoalescer _reads = ReadCoalescer(
    readProperty: _readSingle,
    readMultiple: (deviceId, specs, timeout, {background = false}) =>
        readMultiple(deviceId, specs, timeout: timeout, background: background),
    maxBatchSize: _config.maxCoalescedReads,
    window: _config.coalescingWindow,
  );
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

  /// Alarm and event notifications sent to this client (see
  /// [addListElements] to become a recipient).
  Stream<EventNotificationEvent> get eventNotifications =>
      events.whereType<EventNotificationEvent>();

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

  /// Sends a Who-Has for [object] or for the object named [objectName]
  /// (exactly one of them). Devices hosting it answer with an
  /// [IHaveEvent] (see [events]).
  ///
  /// [lowLimit] and [highLimit] limit the device instance range (-1 for no
  /// limit); [network] selects the broadcast as for [sendWhoIs].
  Future<void> sendWhoHas({
    BacnetObject? object,
    String? objectName,
    int lowLimit = -1,
    int highLimit = -1,
    int network = 0xFFFF,
  }) {
    return Future.sync(() {
      final payload = encodeWhoHas(
        object: object,
        objectName: objectName,
        lowLimit: lowLimit < 0 ? null : lowLimit,
        highLimit: highLimit < 0 ? null : highLimit,
      );
      return _system.call<void>(
        (id) => UnconfirmedRequestCommand(
          id,
          service: BacnetUnconfirmedService.whoHas,
          payload: payload,
          network: network,
        ),
      );
    });
  }

  /// Reads a property of an object.
  ///
  /// Returns the value with its BACnet datatype ([BacnetReal],
  /// [BacnetEnumerated], [BacnetCharacterString], ...; see [BacnetValue]);
  /// arrays and lists are a [BacnetList]. Errors returned by the device
  /// throw a [BacnetProtocolException].
  ///
  /// Concurrent reads of one device are merged into ReadPropertyMultiple
  /// requests unless [BacnetConfig.coalesceReads] is off; reads of an
  /// [arrayIndex] are always sent alone.
  ///
  /// ```dart
  /// final value = await client.readProperty(
  ///   1234,
  ///   BacnetObjectType.analogInput,
  ///   1,
  ///   BacnetPropertyId.presentValue,
  /// );
  /// switch (value) {
  ///   case BacnetReal(:final value):
  ///     print('$value °C');
  ///   default:
  ///     print('unexpected $value');
  /// }
  /// print(value.asDouble); // or null for other datatypes
  /// ```
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
    if (_config.coalesceReads && arrayIndex == -1) {
      final read = _reads.read(
        deviceId,
        objectType,
        instance,
        propertyId,
        timeout: timeout,
        background: background,
      );
      return cancelToken == null ? read : cancelToken.guard(read);
    }
    return _readSingle(
      deviceId,
      objectType,
      instance,
      propertyId,
      timeout,
      arrayIndex: arrayIndex,
      background: background,
      cancelToken: cancelToken,
    );
  }

  /// Reads [property] of [object] as its Dart type.
  ///
  /// Throws a [BacnetDecodeException] if the device returned another
  /// datatype than the property defines, besides the errors of
  /// [readProperty].
  ///
  /// ```dart
  /// final name = await client.read(1234, sensor, BacnetProperties.objectName);
  /// final schedule = await client.read(
  ///     1234, schedule1, BacnetProperties.weeklySchedule);
  /// print(schedule[DateTime.monday]);
  /// ```
  Future<T> read<T>(
    int deviceId,
    BacnetObject object,
    BacnetProperty<T> property, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => readProperty(
    deviceId,
    object.type,
    object.instance,
    property.id,
    timeout: timeout,
    background: background,
    cancelToken: cancelToken,
  ).then(property.decode);

  /// Writes [value] to [property] of [object]; only writable properties
  /// are accepted.
  ///
  /// ```dart
  /// await client.write(1234, output, BacnetProperties.analogPresentValue,
  ///     21.5, priority: 8);
  /// ```
  Future<void> write<T>(
    int deviceId,
    BacnetObject object,
    BacnetWritableProperty<T> property,
    T value, {
    int priority = 16,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => Future.sync(
    () => writeProperty(
      deviceId,
      object.type,
      object.instance,
      property.id,
      property.encodeValue(value),
      priority: priority,
      timeout: timeout,
      background: background,
      cancelToken: cancelToken,
    ),
  );

  Future<BacnetValue> _readSingle(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId,
    Duration? timeout, {
    int arrayIndex = -1,
    bool background = false,
    BacnetCancelToken? cancelToken,
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
      background: background,
      cancelToken: cancelToken,
    );
  }

  /// Reads multiple properties of multiple objects with
  /// ReadPropertyMultiple.
  ///
  /// Returns object → property → result: a [BacnetValue], or a
  /// [BacnetError] for a property the device could not return. A property
  /// may appear only once per object. Requests whose answer does not fit
  /// into one APDU are split automatically.
  ///
  /// ```dart
  /// const sensor = BacnetObject(
  ///   type: BacnetObjectType.analogInput,
  ///   instance: 1,
  /// );
  /// final results = await client.readMultiple(1234, [
  ///   const BacnetReadAccessSpecification(
  ///     objectIdentifier: sensor,
  ///     properties: [
  ///       BacnetPropertyReference(
  ///         propertyIdentifier: BacnetPropertyId.presentValue,
  ///       ),
  ///       BacnetPropertyReference(
  ///         propertyIdentifier: BacnetPropertyId.objectName,
  ///       ),
  ///     ],
  ///   ),
  /// ]);
  /// final properties = results[sensor] ?? const {};
  /// print(properties.valueOf(BacnetPropertyId.objectName)?.asString);
  /// switch (properties[BacnetPropertyId.presentValue]) {
  ///   case BacnetReal(:final value):
  ///     print('$value °C');
  ///   case BacnetError(:final errorCode):
  ///     print('not readable: ${errorCode.label}');
  ///   case _:
  ///     print('missing or unexpected');
  /// }
  /// ```
  Future<Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>>
  readMultiple(
    int deviceId,
    List<BacnetReadAccessSpecification> specs, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    if (specs.isEmpty) return Future.value({});
    // Request methods use callbacks instead of async/await: under load
    // thousands of calls are pending, and in JIT mode suspended async calls
    // are deoptimized one by one when the function's code is invalidated.
    return Future.sync(() {
      checkUniqueProperties(specs);
      return _system
          .confirmed<
            Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>
          >(
            deviceId: deviceId,
            service: BacnetConfirmedService.readPropertyMultiple,
            payload: encodeReadPropertyMultiple(specs),
            decoding: AckDecoding.readPropertyMultiple,
            timeout: timeout,
            background: background,
            cancelToken: cancelToken,
          )
          .catchError(
            (Object error, StackTrace stack) {
              final halves = _splitSpecs(specs);
              if (halves == null) Error.throwWithStackTrace(error, stack);
              return Future.wait([
                readMultiple(
                  deviceId,
                  halves.$1,
                  timeout: timeout,
                  background: background,
                  cancelToken: cancelToken,
                ),
                readMultiple(
                  deviceId,
                  halves.$2,
                  timeout: timeout,
                  background: background,
                  cancelToken: cancelToken,
                ),
              ]).then(_merge);
            },
            test: (error) =>
                error is BacnetAbortException &&
                error.isSegmentationNotSupported,
          );
    });
  }

  static Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>> _merge(
    List<Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>> parts,
  ) {
    final merged =
        <BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>{};
    for (final part in parts) {
      for (final MapEntry(key: object, value: properties) in part.entries) {
        (merged[object] ??= {}).addAll(properties);
      }
    }
    return merged;
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
  /// The class of [value] decides the BACnet datatype, e.g. [BacnetReal]
  /// for analog present values, [BacnetEnumerated] for binary ones and
  /// [BacnetUnsigned] for multi-state ones. A [BacnetNull] relinquishes
  /// [priority]. [BacnetValue.infer] converts values whose type is only
  /// known at run time.
  ///
  /// ```dart
  /// await client.writeProperty(
  ///   1234,
  ///   BacnetObjectType.analogOutput,
  ///   1,
  ///   BacnetPropertyId.presentValue,
  ///   const BacnetReal(75.5),
  ///   priority: 8,
  /// );
  /// ```
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
    return Future.sync(
      () => _system.confirmed<void>(
        deviceId: deviceId,
        service: BacnetConfirmedService.writeProperty,
        payload: encodeWriteProperty(
          objectType,
          instance,
          propertyId,
          value,
          arrayIndex: arrayIndex,
          priority: priority,
        ),
        timeout: timeout,
        background: background,
        cancelToken: cancelToken,
      ),
    );
  }

  /// Writes multiple properties of multiple objects with
  /// WritePropertyMultiple.
  Future<void> writeMultiple(
    int deviceId,
    List<BacnetWriteAccessSpecification> specs, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    if (specs.isEmpty) return Future.value();
    return Future.sync(
      () => _system.confirmed<void>(
        deviceId: deviceId,
        service: BacnetConfirmedService.writePropertyMultiple,
        payload: encodeWritePropertyMultiple(specs),
        timeout: timeout,
        background: background,
        cancelToken: cancelToken,
      ),
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
  Future<List<BacnetObject>> scanDevice(
    int deviceId, {
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) async {
    try {
      // a large array: never merged with other reads
      final value = await _readSingle(
        deviceId,
        BacnetObjectType.device,
        deviceId,
        BacnetPropertyId.objectList,
        null,
        background: background,
        cancelToken: cancelToken,
      );
      return _objects(value);
    } on BacnetAbortException catch (e) {
      if (!e.isSegmentationNotSupported) rethrow;
    } on BacnetProtocolException {
      // some devices refuse to return the whole array
    }
    final length = await readProperty(
      deviceId,
      BacnetObjectType.device,
      deviceId,
      BacnetPropertyId.objectList,
      arrayIndex: 0,
      background: background,
      cancelToken: cancelToken,
    );
    final count = length.asInt ?? 0;
    if (count <= 0) return const [];
    final elements = await Future.wait([
      for (var i = 1; i <= count; i++)
        readProperty(
          deviceId,
          BacnetObjectType.device,
          deviceId,
          BacnetPropertyId.objectList,
          arrayIndex: i,
          background: background,
          cancelToken: cancelToken,
        ),
    ]);
    return _objects(BacnetList(elements));
  }

  static List<BacnetObject> _objects(BacnetValue value) =>
      value.asList.whereType<BacnetObject>().toList();

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

  /// The maximum APDU [deviceId] accepts, from its address binding (null
  /// when the device is not bound yet; any request binds it).
  Future<int?> deviceMaxApdu(int deviceId) => _system
      .call<Object?>((id) => DeviceBindingCommand(id, deviceId))
      .then(
        (binding) => switch (binding) {
          [_, _, final int maxApdu] when maxApdu > 0 => maxApdu,
          _ => null,
        },
      );

  /// The BACnet/IP address of this client (the IPv4 address of its
  /// interface and its UDP port): the recipient devices send notifications
  /// to.
  ///
  /// ```dart
  /// final me = await client.localAddress();
  /// print('${me.ipAddress}:${me.port}');
  /// ```
  Future<BacnetAddressRecipient> localAddress() => _system
      .call<List<int>>(LocalAddressCommand.new)
      .then((mac) => BacnetAddressRecipient(network: 0, mac: mac));

  /// Who-Am-I requests of devices without a configured device instance;
  /// a supervisor answers with [sendYouAre].
  Stream<WhoAmIEvent> get whoAmIRequests => events.whereType<WhoAmIEvent>();

  /// Assigns [deviceId] (and [macAddress]) to the device with [vendorId],
  /// [modelName] and [serialNumber] (You-Are, the answer to a Who-Am-I).
  /// Sent to [destination] (e.g. [WhoAmIEvent.source]), else broadcast on
  /// [network] (0xFFFF: all networks, 0: the local one).
  ///
  /// ```dart
  /// client.whoAmIRequests.listen((request) async {
  ///   final id = await inventory.instanceFor(request.serialNumber);
  ///   await client.sendYouAre(
  ///     vendorId: request.vendorId,
  ///     modelName: request.modelName,
  ///     serialNumber: request.serialNumber,
  ///     deviceId: id,
  ///     destination: request.source,
  ///   );
  /// });
  /// ```
  Future<void> sendYouAre({
    required int vendorId,
    required String modelName,
    required String serialNumber,
    int? deviceId,
    List<int>? macAddress,
    BacnetAddressRecipient? destination,
    int network = 0xFFFF,
  }) => Future.sync(
    () => _system.call<void>(
      (id) => UnconfirmedRequestCommand(
        id,
        service: BacnetUnconfirmedService.youAre,
        payload: encodeYouAre(
          vendorId: vendorId,
          modelName: modelName,
          serialNumber: serialNumber,
          deviceId: deviceId,
          macAddress: macAddress,
        ),
        network: destination?.network ?? network,
        mac: destination == null
            ? null
            : destination.network == 0
            ? destination.mac
            : const [],
        adr: destination == null || destination.network == 0
            ? const []
            : destination.mac,
      ),
    ),
  );

  /// Writes [changes] to the Channel objects of all devices whose
  /// Control_Groups contain [groupNumber] (WriteGroup, broadcast on
  /// [network]) at [writePriority]; [inhibitDelay] makes the channels skip
  /// their write delay.
  ///
  /// ```dart
  /// // dim the lights of group 5 to 50 % and switch channel 3 off
  /// await client.writeGroup(5, [
  ///   BacnetGroupChannelValue(1, const BacnetReal(50)),
  ///   BacnetGroupChannelValue(3, const BacnetUnsigned(0)),
  /// ]);
  /// ```
  Future<void> writeGroup(
    int groupNumber,
    List<BacnetGroupChannelValue> changes, {
    int writePriority = 16,
    bool? inhibitDelay,
    int? deviceId,
    int network = 0xFFFF,
  }) => Future.sync(
    () => _system.call<void>(
      (id) => UnconfirmedRequestCommand(
        id,
        service: BacnetUnconfirmedService.writeGroup,
        payload: encodeWriteGroup(
          groupNumber,
          changes,
          writePriority: writePriority,
          inhibitDelay: inhibitDelay,
        ),
        deviceId: deviceId,
        network: network,
      ),
    ),
  );

  /// Network layer messages received from routers and other devices
  /// (I-Am-Router-To-Network, Network-Number-Is, Reject-Message-To-Network,
  /// ...). [BacnetNetworkDiscovery] builds router discovery on them.
  Stream<NetworkMessageEvent> get networkMessages =>
      events.whereType<NetworkMessageEvent>();

  /// Sends a network layer message (clause 6.4).
  ///
  /// The message is broadcast on the local network unless [ip] (an IPv4
  /// address or host name) and [port] name the next hop. [network] and
  /// [adr] address a device behind a router: [network] alone is a
  /// broadcast on that network, 0xFFFF a global broadcast.
  ///
  /// ```dart
  /// // ask the router at 192.168.1.1 for its routing table
  /// await client.sendNetworkMessage(BacnetInitializeRoutingTable(),
  ///     ip: '192.168.1.1');
  /// ```
  Future<void> sendNetworkMessage(
    BacnetNetworkMessage message, {
    String? ip,
    int port = 47808,
    int network = 0,
    List<int> adr = const [],
  }) async {
    RangeError.checkValueInInterval(network, 0, 0xFFFF, 'network');
    if (adr.length > 7 || (adr.isNotEmpty && network == 0)) {
      throw ArgumentError.value(adr, 'adr', 'needs a network, 1 to 7 bytes');
    }
    final mac = ip == null ? const <int>[] : await resolveBacnetIp(ip, port);
    return _system.call<void>(
      (id) => NetworkMessageCommand(
        id,
        messageType: message.type,
        payload: message.encode(),
        mac: mac,
        network: network,
        adr: adr,
        vendorId: message.vendorId,
      ),
    );
  }

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
    BacnetObjectType objectType,
    int instance, {
    BacnetPropertyId propId = BacnetPropertyId.presentValue,
    int processId = 1,
    Duration lifetime = const Duration(minutes: 5),
    bool confirmed = false,
    double? covIncrement,
    Duration? timeout,
  }) {
    final lifetimeSeconds = lifetime.inSeconds;
    final usePropertyService =
        propId != BacnetPropertyId.presentValue || covIncrement != null;
    return Future.sync(
      () => _system.confirmed<void>(
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
      ),
    );
  }

  /// Cancels a COV subscription created with [subscribeCOV].
  Future<void> unsubscribeCOV(
    int deviceId,
    BacnetObjectType objectType,
    int instance, {
    BacnetPropertyId propId = BacnetPropertyId.presentValue,
    int processId = 1,
    Duration? timeout,
  }) {
    final usePropertyService = propId != BacnetPropertyId.presentValue;
    return Future.sync(
      () => _system.confirmed<void>(
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
      ),
    );
  }

  /// Subscribes to changes of several properties of several objects with
  /// one request (SubscribeCOVPropertyMultiple), e.g. to watch a whole
  /// plant room. The device sends COVNotificationMultiple, which arrive as
  /// one [CovNotificationEvent] per object on [covEvents] (with
  /// [CovNotificationEvent.changeTimes] for timestamped references).
  /// [maxNotificationDelay] lets the device collect changes before it
  /// notifies.
  ///
  /// When the device refuses a subscription the
  /// [BacnetProtocolException.firstFailedSubscription] names it; devices
  /// without the service reject the request
  /// ([BacnetRejectException]), use [subscribeCOV] for those.
  ///
  /// ```dart
  /// await client.subscribeCOVPropertyMultiple(1234, [
  ///   BacnetCovSubscriptionSpecification(supplyTemp, const [
  ///     BacnetCovReference(BacnetPropertyId.presentValue, covIncrement: 0.2),
  ///     BacnetCovReference(BacnetPropertyId.statusFlags),
  ///   ]),
  ///   BacnetCovSubscriptionSpecification(fan, const [
  ///     BacnetCovReference(BacnetPropertyId.presentValue, timestamped: true),
  ///   ]),
  /// ], processId: 7, lifetime: const Duration(minutes: 10));
  /// ```
  Future<void> subscribeCOVPropertyMultiple(
    int deviceId,
    List<BacnetCovSubscriptionSpecification> specifications, {
    int processId = 1,
    Duration lifetime = const Duration(minutes: 5),
    bool confirmed = false,
    Duration? maxNotificationDelay,
    Duration? timeout,
  }) => Future.sync(
    () => _system.confirmed<void>(
      deviceId: deviceId,
      service: BacnetConfirmedService.subscribeCovPropertyMultiple,
      payload: encodeSubscribeCovPropertyMultiple(
        subscriberProcessId: processId,
        specifications: specifications,
        confirmed: confirmed,
        lifetime: lifetime.inSeconds,
        maxNotificationDelay: maxNotificationDelay?.inSeconds,
      ),
      timeout: timeout,
    ),
  );

  /// Cancels the subscriptions of [specifications] made with
  /// [subscribeCOVPropertyMultiple].
  Future<void> unsubscribeCOVPropertyMultiple(
    int deviceId,
    List<BacnetCovSubscriptionSpecification> specifications, {
    int processId = 1,
    Duration? timeout,
  }) => Future.sync(
    () => _system.confirmed<void>(
      deviceId: deviceId,
      service: BacnetConfirmedService.subscribeCovPropertyMultiple,
      payload: encodeSubscribeCovPropertyMultiple(
        subscriberProcessId: processId,
        specifications: specifications,
      ),
      timeout: timeout,
    ),
  );

  // ---- lists ----------------------------------------------------------------

  /// Adds [elements] (the elements one after another) to a list property
  /// with AddListElement; elements already in the list are not added
  /// twice.
  Future<void> addListElement(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId,
    BacnetValue elements, {
    int arrayIndex = -1,
    Duration? timeout,
  }) => Future.sync(
    () => _system.confirmed<void>(
      deviceId: deviceId,
      service: BacnetConfirmedService.addListElement,
      payload: encodeListElements(
        objectType,
        instance,
        propertyId,
        elements,
        arrayIndex: arrayIndex,
      ),
      timeout: timeout,
    ),
  );

  /// Removes [elements] (the elements one after another) from a list
  /// property with RemoveListElement.
  Future<void> removeListElement(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId,
    BacnetValue elements, {
    int arrayIndex = -1,
    Duration? timeout,
  }) => Future.sync(
    () => _system.confirmed<void>(
      deviceId: deviceId,
      service: BacnetConfirmedService.removeListElement,
      payload: encodeListElements(
        objectType,
        instance,
        propertyId,
        elements,
        arrayIndex: arrayIndex,
      ),
      timeout: timeout,
    ),
  );

  /// Adds [elements] to the list [property] of [object].
  ///
  /// ```dart
  /// // receive the alarms of notification class 1 of device 1234
  /// await client.addListElements(
  ///   1234,
  ///   const BacnetObject(type: BacnetObjectType.notificationClass, instance: 1),
  ///   BacnetProperties.recipientList,
  ///   [BacnetDestination(recipient: BacnetRecipient.ip('192.168.1.10', 47808))],
  /// );
  /// client.eventNotifications.listen(print);
  /// ```
  Future<void> addListElements<E>(
    int deviceId,
    BacnetObject object,
    BacnetWritableProperty<List<E>> property,
    List<E> elements, {
    Duration? timeout,
  }) => Future.sync(
    () => addListElement(
      deviceId,
      object.type,
      object.instance,
      property.id,
      property.encodeValue(elements),
      timeout: timeout,
    ),
  );

  /// Removes [elements] from the list [property] of [object]; an element
  /// must match an entry of the list exactly.
  Future<void> removeListElements<E>(
    int deviceId,
    BacnetObject object,
    BacnetWritableProperty<List<E>> property,
    List<E> elements, {
    Duration? timeout,
  }) => Future.sync(
    () => removeListElement(
      deviceId,
      object.type,
      object.instance,
      property.id,
      property.encodeValue(elements),
      timeout: timeout,
    ),
  );

  // ---- alarms and events ----------------------------------------------------

  /// Acknowledges the transition of [object] into [eventState] that
  /// happened at [timeStamp] (AcknowledgeAlarm).
  ///
  /// [source] names who acknowledges, e.g. the operator; [time] is the time
  /// of the acknowledgement (now by default). The device answers with an
  /// error if [eventState] or [timeStamp] is not the current transition.
  Future<void> acknowledgeAlarm(
    int deviceId,
    BacnetObject object,
    BacnetEventState eventState,
    BacnetTimeStamp timeStamp, {
    required String source,
    int processId = 0,
    DateTime? time,
    Duration? timeout,
  }) => Future.sync(
    () => _system.confirmed<void>(
      deviceId: deviceId,
      service: BacnetConfirmedService.acknowledgeAlarm,
      payload: encodeAcknowledgeAlarm(
        processId: processId,
        object: object,
        eventState: eventState,
        timeStamp: timeStamp,
        source: source,
        timeOfAcknowledgment: BacnetTimeStampDateTime(
          BacnetDateTime.fromDateTime(time ?? DateTime.now()),
        ),
      ),
      timeout: timeout,
    ),
  );

  /// Acknowledges the transition [notification] reported.
  ///
  /// ```dart
  /// client.eventNotifications
  ///     .where((alarm) => alarm.ackRequired)
  ///     .listen((alarm) => client.acknowledgeEvent(alarm, source: 'operator'));
  /// ```
  Future<void> acknowledgeEvent(
    EventNotificationEvent notification, {
    required String source,
    DateTime? time,
    Duration? timeout,
  }) => acknowledgeAlarm(
    notification.deviceId,
    notification.object,
    notification.toState,
    notification.timeStamp,
    source: source,
    processId: notification.processId,
    time: time,
    timeout: timeout,
  );

  /// Returns the objects of [deviceId] that are in an event state other
  /// than normal or have unacknowledged transitions (GetEventInformation,
  /// repeated while the device reports more).
  Future<List<BacnetEventSummary>> getEventInformation(
    int deviceId, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) async {
    final summaries = <BacnetEventSummary>[];
    BacnetObject? last;
    while (true) {
      final EventInformation page = await _system.confirmed(
        deviceId: deviceId,
        service: BacnetConfirmedService.getEventInformation,
        payload: encodeGetEventInformation(lastReceived: last),
        decoding: AckDecoding.getEventInformation,
        timeout: timeout,
        background: background,
        cancelToken: cancelToken,
      );
      summaries.addAll(page.summaries);
      if (!page.moreEvents || page.summaries.isEmpty) {
        return List.unmodifiable(summaries);
      }
      last = page.summaries.last.object;
    }
  }

  /// Returns the objects of [deviceId] in alarm (GetAlarmSummary).
  ///
  /// Newer devices may support only [getEventInformation].
  Future<List<BacnetAlarmSummary>> getAlarmSummary(
    int deviceId, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => _system.confirmed(
    deviceId: deviceId,
    service: BacnetConfirmedService.getAlarmSummary,
    payload: Uint8List(0),
    decoding: AckDecoding.getAlarmSummary,
    timeout: timeout,
    background: background,
    cancelToken: cancelToken,
  );

  /// Reads the items of a list property selected by [range] with
  /// ReadRange (the whole list by default).
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
  }) {
    return _system.confirmed(
      deviceId: deviceId,
      service: BacnetConfirmedService.readRange,
      payload: encodeReadRange(
        objectType,
        instance,
        propertyId,
        arrayIndex: arrayIndex,
        range: range,
      ),
      decoding: AckDecoding.readRange,
      timeout: timeout,
      background: background,
      cancelToken: cancelToken,
    );
  }

  /// Reads records of a Trend Log object.
  ///
  /// By default reads the newest [count] records (by position, backwards
  /// from the end of the buffer). Pass [fromSequenceNumber] to read forward
  /// from a sequence number (incremental collection).
  Future<TrendLogData> getTrendLog(
    int deviceId,
    int instance, {
    BacnetPropertyId logBufferPropId = BacnetPropertyId.logBuffer,
    int count = 100,
    int? fromSequenceNumber,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) async {
    final ReadRangeResult result;
    if (fromSequenceNumber != null) {
      result = await readRange(
        deviceId,
        BacnetObjectType.trendLog,
        instance,
        logBufferPropId,
        range: BacnetRange.bySequenceNumber(fromSequenceNumber, count),
        timeout: timeout,
        background: background,
        cancelToken: cancelToken,
      );
    } else {
      final recordCount = await readProperty(
        deviceId,
        BacnetObjectType.trendLog,
        instance,
        BacnetPropertyId.recordCount,
        timeout: timeout,
        background: background,
        cancelToken: cancelToken,
      );
      final total = recordCount.asInt ?? 0;
      if (total == 0) {
        return const TrendLogData(itemCount: 0, totalRecords: 0);
      }
      result = await readRange(
        deviceId,
        BacnetObjectType.trendLog,
        instance,
        logBufferPropId,
        range: BacnetRange.byPosition(total, -count),
        timeout: timeout,
        background: background,
        cancelToken: cancelToken,
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

  // ---- device management ----------------------------------------------------

  /// Enables or disables the communication of [deviceId]
  /// (DeviceCommunicationControl) for [duration] (whole minutes, null for
  /// indefinitely).
  ///
  /// [BacnetCommunicationState.disableInitiation] stops the device from
  /// initiating requests (I-Am, notifications) but it still answers;
  /// [BacnetCommunicationState.disable] also stops the answers except to
  /// DeviceCommunicationControl and ReinitializeDevice. Devices that
  /// require a [password] answer with a password failure without it.
  ///
  /// ```dart
  /// await client.deviceCommunicationControl(
  ///     1234, BacnetCommunicationState.disableInitiation,
  ///     duration: const Duration(minutes: 30), password: 'secret');
  /// ```
  Future<void> deviceCommunicationControl(
    int deviceId,
    BacnetCommunicationState state, {
    Duration? duration,
    String? password,
    Duration? timeout,
  }) => Future.sync(
    () => _system.confirmed<void>(
      deviceId: deviceId,
      service: BacnetConfirmedService.deviceCommunicationControl,
      payload: encodeDeviceCommunicationControl(
        state,
        duration: duration,
        password: password,
      ),
      timeout: timeout,
    ),
  );

  /// Restarts [deviceId] or controls its backup and restore procedure
  /// (ReinitializeDevice).
  ///
  /// ```dart
  /// await client.reinitializeDevice(1234, BacnetReinitializedState.warmStart,
  ///     password: 'secret');
  /// ```
  Future<void> reinitializeDevice(
    int deviceId,
    BacnetReinitializedState state, {
    String? password,
    Duration? timeout,
  }) => Future.sync(
    () => _system.confirmed<void>(
      deviceId: deviceId,
      service: BacnetConfirmedService.reinitializeDevice,
      payload: encodeReinitializeDevice(state, password: password),
      timeout: timeout,
    ),
  );

  /// Creates an object in [deviceId] (CreateObject) and returns it: an
  /// object of [type] whose instance the device chooses, or [object].
  ///
  /// [initialValues] are written while creating the object. When the
  /// device rejects one, the [BacnetProtocolException] names its position
  /// in [BacnetProtocolException.firstFailedElement] (1 based).
  ///
  /// ```dart
  /// final setpoint = await client.createObject(1234,
  ///     type: BacnetObjectType.analogValue,
  ///     initialValues: const [
  ///       BacnetPropertyValue(
  ///         propertyIdentifier: BacnetPropertyId.objectName,
  ///         value: BacnetCharacterString('Setpoint'),
  ///       ),
  ///     ]);
  /// ```
  Future<BacnetObject> createObject(
    int deviceId, {
    BacnetObjectType? type,
    BacnetObject? object,
    List<BacnetPropertyValue> initialValues = const [],
    Duration? timeout,
  }) => Future.sync(
    () => _system.confirmed<BacnetObject>(
      deviceId: deviceId,
      service: BacnetConfirmedService.createObject,
      payload: encodeCreateObject(
        type: type,
        object: object,
        initialValues: initialValues,
      ),
      decoding: AckDecoding.createObject,
      timeout: timeout,
    ),
  );

  /// Deletes [object] from [deviceId] (DeleteObject).
  Future<void> deleteObject(
    int deviceId,
    BacnetObject object, {
    Duration? timeout,
  }) => Future.sync(
    () => _system.confirmed<void>(
      deviceId: deviceId,
      service: BacnetConfirmedService.deleteObject,
      payload: encodeDeleteObject(object),
      timeout: timeout,
    ),
  );

  // ---- files ----------------------------------------------------------------

  /// Reads up to [count] octets from position [start] of File object
  /// [fileInstance] (AtomicReadFile, stream access).
  ///
  /// The answer has to fit into one APDU of the device unless it segments
  /// answers; `readFile` (BacnetFileTransfer) reads whole files in fitting
  /// chunks.
  Future<BacnetFileChunk> readFileStream(
    int deviceId,
    int fileInstance, {
    required int start,
    required int count,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) =>
      Future.sync(
        () => _system.confirmed<AtomicReadFileData>(
          deviceId: deviceId,
          service: BacnetConfirmedService.atomicReadFile,
          payload: encodeAtomicReadFile(
            fileInstance,
            start: start,
            count: count,
          ),
          decoding: AckDecoding.atomicReadFile,
          timeout: timeout,
          background: background,
          cancelToken: cancelToken,
        ),
      ).then(
        (answer) =>
            answer.chunk ??
            (throw const BacnetDecodeException(
              'AtomicReadFile-ACK with records for a stream request',
            )),
      );

  /// Reads up to [count] records from record [start] of File object
  /// [fileInstance] (AtomicReadFile, record access).
  Future<BacnetFileRecords> readFileRecords(
    int deviceId,
    int fileInstance, {
    required int start,
    required int count,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) =>
      Future.sync(
        () => _system.confirmed<AtomicReadFileData>(
          deviceId: deviceId,
          service: BacnetConfirmedService.atomicReadFile,
          payload: encodeAtomicReadFile(
            fileInstance,
            start: start,
            count: count,
            records: true,
          ),
          decoding: AckDecoding.atomicReadFile,
          timeout: timeout,
          background: background,
          cancelToken: cancelToken,
        ),
      ).then(
        (answer) =>
            answer.records ??
            (throw const BacnetDecodeException(
              'AtomicReadFile-ACK with a stream for a record request',
            )),
      );

  /// Writes [data] to File object [fileInstance] at position [start]
  /// (AtomicWriteFile, stream access; -1 appends) and returns the position
  /// the device wrote to.
  Future<int> writeFileStream(
    int deviceId,
    int fileInstance,
    List<int> data, {
    int start = 0,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => Future.sync(
    () => _system.confirmed<int>(
      deviceId: deviceId,
      service: BacnetConfirmedService.atomicWriteFile,
      payload: encodeAtomicWriteFileStream(fileInstance, data, start: start),
      decoding: AckDecoding.atomicWriteFile,
      timeout: timeout,
      background: background,
      cancelToken: cancelToken,
    ),
  );

  /// Writes [records] to File object [fileInstance] from record [start]
  /// (AtomicWriteFile, record access; -1 appends) and returns the first
  /// record the device wrote.
  Future<int> writeFileRecords(
    int deviceId,
    int fileInstance,
    List<List<int>> records, {
    int start = 0,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => Future.sync(
    () => _system.confirmed<int>(
      deviceId: deviceId,
      service: BacnetConfirmedService.atomicWriteFile,
      payload: encodeAtomicWriteFileRecords(
        fileInstance,
        records,
        start: start,
      ),
      decoding: AckDecoding.atomicWriteFile,
      timeout: timeout,
      background: background,
      cancelToken: cancelToken,
    ),
  );

  // ---- vendor services and messages -----------------------------------------

  /// Calls the vendor specific service [serviceNumber] of [vendorId] in
  /// [deviceId] (ConfirmedPrivateTransfer) and returns its result block.
  Future<BacnetValue?> privateTransfer(
    int deviceId,
    int vendorId,
    int serviceNumber, {
    BacnetValue? parameters,
    Duration? timeout,
  }) => Future.sync(
    () => _system.confirmed<BacnetValue?>(
      deviceId: deviceId,
      service: BacnetConfirmedService.privateTransfer,
      payload: encodePrivateTransfer(
        vendorId,
        serviceNumber,
        parameters: parameters,
      ),
      decoding: AckDecoding.privateTransfer,
      timeout: timeout,
    ),
  );

  /// Sends an UnconfirmedPrivateTransfer to [deviceId], or as broadcast.
  Future<void> sendPrivateTransfer(
    int vendorId,
    int serviceNumber, {
    BacnetValue? parameters,
    int? deviceId,
    int network = 0xFFFF,
  }) => Future.sync(
    () => _system.call<void>(
      (id) => UnconfirmedRequestCommand(
        id,
        service: BacnetUnconfirmedService.privateTransfer,
        payload: encodePrivateTransfer(
          vendorId,
          serviceNumber,
          parameters: parameters,
        ),
        deviceId: deviceId,
        network: network,
      ),
    ),
  );

  /// Sends a text to [deviceId] and waits for the acknowledgement
  /// (ConfirmedTextMessage). The message names the device instance of
  /// [BacnetConfig.deviceInstance] as its source.
  Future<void> textMessage(
    int deviceId,
    String message, {
    bool urgent = false,
    int? classNumber,
    String? classText,
    Duration? timeout,
  }) => Future.sync(
    () => _system.confirmed<void>(
      deviceId: deviceId,
      service: BacnetConfirmedService.textMessage,
      payload: encodeTextMessage(
        _config.deviceInstance,
        message,
        urgent: urgent,
        classNumber: classNumber,
        classText: classText,
      ),
      timeout: timeout,
    ),
  );

  /// Sends an UnconfirmedTextMessage to [deviceId], or as broadcast.
  Future<void> sendTextMessage(
    String message, {
    int? deviceId,
    int network = 0xFFFF,
    bool urgent = false,
    int? classNumber,
    String? classText,
  }) => Future.sync(
    () => _system.call<void>(
      (id) => UnconfirmedRequestCommand(
        id,
        service: BacnetUnconfirmedService.textMessage,
        payload: encodeTextMessage(
          _config.deviceInstance,
          message,
          urgent: urgent,
          classNumber: classNumber,
          classText: classText,
        ),
        deviceId: deviceId,
        network: network,
      ),
    ),
  );

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
    BacnetConfirmedService service,
    Uint8List serviceData, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    return _system.confirmed(
      deviceId: deviceId,
      service: service,
      payload: serviceData,
      decoding: AckDecoding.raw,
      timeout: timeout,
      background: background,
      cancelToken: cancelToken,
    );
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
