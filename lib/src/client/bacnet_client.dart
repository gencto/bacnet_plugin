import 'dart:async';

import 'package:bacnet_plugin/bacnet_plugin.dart';

import '../native/bacnet_system.dart';

export '../core/exceptions.dart';
export '../core/logger.dart';
export '../core/types.dart';
export '../models/bacnet_object.dart';
export '../models/internal/worker_message.dart';
export '../models/rpm_models.dart';
export '../models/trend_log_data.dart';
export '../models/wpm_models.dart';

/// BACnet client for communication with BACnet devices.
///
/// This class provides high-level methods for BACnet client operations including
/// property reading/writing, device discovery, and Change of Value (COV) subscriptions.
///
/// The client uses an isolate-based architecture to prevent blocking the UI thread
/// during native BACnet operations.
///
/// Example usage:
/// ```dart
/// // Create client with custom logger
/// final client = BacnetClient(logger: DeveloperBacnetLogger());
///
/// // Start the BACnet stack
/// await client.start(interface: '192.168.1.100');
///
/// // Discover devices
/// await client.sendWhoIs();
///
/// // Read a property
/// final value = await client.readProperty(
///   deviceId: 1234,
///   objectType: BacnetObjectType.analogInput,
///   instance: 1,
///   propertyId: BacnetPropertyId.presentValue,
/// );
/// ```
class BacnetClient {
  /// Creates a BACnet client.
  ///
  /// [logger] is an optional custom logger implementation. If not provided,
  /// [DeveloperBacnetLogger] will be used.
  BacnetClient({BacnetLogger? logger}) {
    if (logger != null) {
      _system.setLogger(logger);
    }
  }

  final BacnetSystem _system = BacnetSystem.instance;

  /// Stream of BACnet events from the native worker.
  ///
  /// Emits events such as I-Am responses, COV notifications, and property updates.
  /// Subscribe to this stream to receive asynchronous BACnet events.
  Stream<dynamic> get events => _system.events;

  /// Logs a message using the configured logger.
  void log(
    BacnetLogLevel level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    _system.log(level, message, error, stackTrace);
  }

  /// Starts the BACnet client stack.
  ///
  /// Must be called before any other operations. Initializes the native
  /// BACnet stack and spawns a worker isolate for handling BACnet communication.
  ///
  /// [interface] is the local network interface IP to bind to. If null,
  /// binds to all interfaces.
  /// [port] is the UDP port for BACnet/IP (default: 47808).
  Future<void> start({String? interface, int port = 47808}) async {
    await _system.start(interface: interface, port: port);
  }

  /// Sends a Who-Is broadcast to discover BACnet devices.
  ///
  /// [lowLimit] and [highLimit] optionally limit the device ID range.
  /// Set to -1 for no limit (discover all devices).
  ///
  /// Listen to [events] stream for I-Am responses from devices.
  Future<void> sendWhoIs({int lowLimit = -1, int highLimit = -1}) async {
    await _system.send(WhoIsRequest(lowLimit: lowLimit, highLimit: highLimit));
  }

  /// Reads a single property from a BACnet object.
  ///
  /// [deviceId] is the target device ID.
  /// [objectType] is the BACnet object type (use [BacnetObjectType] constants).
  /// [instance] is the object instance number.
  /// [propertyId] is the property identifier (use [BacnetPropertyId] constants).
  /// [arrayIndex] is the optional array index for array properties (-1 for non-arrays).
  ///
  /// Returns the property value. Throws [BacnetTimeoutException] if no response
  /// is received within the timeout period.
  ///
  /// Example:
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
  }) async {
    return _system.sendReadProperty(
      deviceId,
      objectType,
      instance,
      propertyId,
      arrayIndex: arrayIndex,
    );
  }

  /// Reads multiple properties from multiple objects in a single request.
  ///
  /// This is more efficient than multiple [readProperty] calls as it uses
  /// the BACnet ReadPropertyMultiple service.
  ///
  /// [deviceId] is the target device ID.
  /// [specs] is a list of [BacnetReadAccessSpecification] defining what to read.
  ///
  /// Returns a map of object identifiers to property maps.
  ///
  /// Example:
  /// ```dart
  /// final specs = [
  ///   BacnetReadAccessSpecification(
  ///     objectIdentifier: BacnetObject(type: 0, instance: 1),
  ///     properties: [
  ///       BacnetPropertyReference(propertyIdentifier: 85), // Present Value
  ///       BacnetPropertyReference(propertyIdentifier: 77), // Object Name
  ///     ],
  ///   ),
  /// ];
  /// final results = await client.readMultiple(1234, specs);
  /// ```
  Future<Map<String, Map<int, dynamic>>> readMultiple(
    int deviceId,
    List<BacnetReadAccessSpecification> specs,
  ) async {
    return _system.sendReadPropertyMultiple(deviceId, specs);
  }

  /// Writes a value to a BACnet property.
  ///
  /// [deviceId] is the target device ID.
  /// [objectType] is the BACnet object type.
  /// [instance] is the object instance number.
  /// [propertyId] is the property identifier to write to.
  /// [value] is the value to write.
  /// [priority] is the write priority (1-16, default: 16).
  /// [tag] is the BACnet application tag for the value (default: 4 for real).
  ///
  /// Example:
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
    int tag = 4,
  }) async {
    await _system.send(
      WritePropertyRequest(
        deviceId: deviceId,
        objectType: objectType,
        instance: instance,
        propertyId: propertyId,
        value: value,
        priority: priority,
        tag: tag,
      ),
    );
  }

  /// Registers this client as a Foreign Device with a BBMD (BACnet Broadcast Management Device).
  ///
  /// Required when communicating across network boundaries or routers.
  ///
  /// [ip] is the BBMD IP address.
  /// [port] is the BBMD port (default: 47808).
  /// [ttl] is the Time-To-Live in seconds (default: 120).
  ///
  /// The registration must be renewed before the TTL expires.
  Future<void> registerForeignDevice(
    String ip, {
    int port = 47808,
    int ttl = 120,
  }) async {
    await _system.send(RegisterFdrRequest(ip: ip, port: port, ttl: ttl));
  }

  /// Scans a device to discover its objects.
  ///
  /// Reads the Object_List property from the device object to enumerate
  /// all objects on the device. Currently limited to the first 10 objects.
  ///
  /// [deviceId] is the device ID to scan.
  /// [endDeviceId] is currently unused (reserved for future use).
  ///
  /// Returns a list of [BacnetObject] instances discovered on the device.
  /// Returns an empty list if the scan fails or no objects are found.
  Future<List<BacnetObject>> scanDevice(
    int deviceId, [
    int? endDeviceId,
  ]) async {
    try {
      // Read the length of the Object_List array (index 0)
      final len = await readProperty(
        deviceId,
        BacnetObjectType.device,
        deviceId,
        BacnetPropertyId.objectList,
        arrayIndex: 0,
      );

      if (len is int && len > 0) {
        final objects = <BacnetObject>[];
        final limit = len > 10 ? 10 : len;

        for (var i = 1; i <= limit; i++) {
          final objIdData = await readProperty(
            deviceId,
            BacnetObjectType.device,
            deviceId,
            BacnetPropertyId.objectList,
            arrayIndex: i,
          );
          if (objIdData is Map<String, dynamic>) {
            final type = objIdData['type'];
            final instance = objIdData['instance'];
            if (type is int && instance is int) {
              objects.add(BacnetObject(type: type, instance: instance));
            }
          }
        }
        return objects;
      }
    } on Exception {
      // Suppress errors and return empty list
    }
    return [];
  }

  /// Manually adds a device binding (IP address mapping).
  ///
  /// Useful when a device's network location is known but it hasn't
  /// responded to Who-Is, or for static device configurations.
  ///
  /// [deviceId] is the device instance number.
  /// [ip] is the device IP address.
  /// [port] is the device port (default: 47808).
  Future<void> addDeviceBinding(
    int deviceId,
    String ip, {
    int port = 47808,
  }) async {
    await _system.send(
      AddDeviceBindingRequest(deviceId: deviceId, ip: ip, port: port),
    );
  }

  /// Subscribes to Change of Value (COV) notifications for an object.
  ///
  /// When the property value changes, the device will send unsolicited
  /// COV notifications. Listen to [events] stream for these notifications.
  ///
  /// [deviceId] is the device ID containing the object.
  /// [objectType] is the object type to subscribe to.
  /// [instance] is the object instance number.
  /// [propId] is the property ID to monitor (default: 85 for Present Value).
  Future<void> subscribeCOV(
    int deviceId,
    int objectType,
    int instance, {
    int propId = 85,
  }) async {
    await _system.send(
      SubscribeCOVRequest(
        deviceId: deviceId,
        objectType: objectType,
        instance: instance,
        propertyId: propId,
      ),
    );
  }

  /// Retrieves trend log data from a Trend Log object.
  ///
  /// Note: This is currently a stub implementation and returns empty data.
  /// Full implementation is planned for a future update.
  ///
  /// [deviceId] is the device ID.
  /// [instance] is the trend log object instance.
  Future<TrendLogData> getTrendLog(
    int deviceId,
    int instance, {
    int logBufferPropId = 131,
  }) async {
    final response = await _system.sendReadRange(
      deviceId,
      objectType: 20, // Trend Log
      instance: instance,
      propertyId: logBufferPropId,
      // Default to reading by position, all items?
      // count: 0 means all? Or need positive count.
      // ASHRAE 135: If count is 0, no items returned?
      // Usually, to read all, we might need multiple requests or check ItemCount.
      // For now, let's try to read most recent items (negative count).
      // count: -10 ??
      // Let's rely on default behavior or user parameter?
      // The stub had no params. I'll read "some" items.
      count: -10, // Read last 10 items
      requestType: 1, // By Position
      reference: 0, // End? Or Reference 1?
      // If by position, Reference is index.
      // If count is negative, reference is starting index (counting backwards).
    );

    // Convert raw data to TrendLogEntries
    // Note: Manual parsing in onReadRangeAck is currently limited.
    // Assuming data contains parsed maps if successful.
    final entries = <TrendLogEntry>[];
    if (response.data is List) {
      final listData = response.data as List;
      for (final item in listData) {
        if (item is Map<String, dynamic>) {
          // Parse entry
          // entries.add(TrendLogEntry(...));
        }
      }
    }

    return TrendLogData(
      itemCount: response.itemCount,
      totalRecords: response.itemCount, // Approximation
      entries: entries,
    );
  }

  /// Writes multiple properties to multiple objects in a single request.
  ///
  /// More efficient than multiple [writeProperty] calls.
  ///
  /// [deviceId] is the target device ID.
  /// [specs] is a list of [BacnetWriteAccessSpecification] defining what to write.
  Future<void> writeMultiple(
    int deviceId,
    List<BacnetWriteAccessSpecification> specs,
  ) async {
    await _system.sendWritePropertyMultiple(deviceId, specs);
  }

  /// Disposes of the client and releases resources.
  ///
  /// Stops the worker isolate and closes event streams.
  /// The client cannot be used after calling dispose.
  void dispose() {
    _system.dispose();
  }
}
