import '../core/logger.dart';
import '../models/internal/worker_message.dart';
import '../native/bacnet_system.dart';

export '../core/logger.dart';

/// BACnet server for hosting BACnet objects and responding to client requests.
///
/// This class provides functionality to create a BACnet device that can
/// respond to requests from other BACnet clients on the network.
///
/// Example usage:
/// ```dart
/// final server = BacnetServer(logger: DeveloperBacnetLogger());
///
/// // Start the server
/// await server.start(interface: '192.168.1.100');
///
/// // Initialize as a device
/// await server.init(deviceId: 5678, deviceName: 'My BACnet Server');
///
/// // Add objects
/// await server.addObject(
///   BacnetObjectType.analogInput,
///   1, // instance
/// );
///
/// // Listen for write requests
/// server.writeEvents.listen((event) {
///   print('Property written: ${event.objectType}:${event.instance}');
/// });
/// ```
class BacnetServer {
  /// Creates a BACnet server.
  ///
  /// [logger] is an optional custom logger implementation. If not provided,
  /// [DeveloperBacnetLogger] will be used.
  BacnetServer({BacnetLogger? logger}) {
    if (logger != null) {
      _system.setLogger(logger);
    }
  }

  final BacnetSystem _system = BacnetSystem.instance;

  /// Stream of write notification events from external BACnet clients.
  ///
  /// Emits [WriteNotificationResponse] events when clients write to
  /// properties on this server's objects.
  ///
  /// Subscribe to this stream to handle write requests:
  /// ```dart
  /// server.writeEvents.listen((notification) {
  ///   print('Write to ${notification.objectType}:${notification.instance}');
  ///   print('Property ${notification.propertyId} = ${notification.value}');
  /// });
  /// ```
  Stream<WriteNotificationResponse> get writeEvents => _system.events
      .where((e) => e is WriteNotificationResponse)
      .cast<WriteNotificationResponse>();

  /// Starts the BACnet server stack.
  ///
  /// Must be called before any other server operations. Initializes the
  /// native BACnet stack and spawns a worker isolate.
  ///
  /// [interface] is the local network interface IP to bind to. If null,
  /// binds to all interfaces.
  /// [port] is the UDP port for BACnet/IP (default: 47808).
  Future<void> start({String? interface, int port = 47808}) async {
    await _system.start(interface: interface, port: port);
  }

  /// Initializes this server as a BACnet device.
  ///
  /// Must be called after [start] and before adding objects.
  ///
  /// [deviceId] is the unique device instance number (typically > 4194303 for local devices).
  /// [deviceName] is the human-readable device name.
  ///
  /// Example:
  /// ```dart
  /// await server.init(
  ///   deviceId: 4194304,
  ///   deviceName: 'Building Controller',
  /// );
  /// ```
  Future<void> init(int deviceId, String deviceName) async {
    await _system.send(InitServerRequest(deviceId, deviceName));
  }

  /// Adds a BACnet object to this server.
  ///
  /// The object will be available for reading and writing by BACnet clients.
  ///
  /// [objectType] is the BACnet object type (use [BacnetObjectType] constants).
  /// [instance] is the unique instance number for this object type.
  ///
  /// Example:
  /// ```dart
  /// // Add Analog Input object instance 1
  /// await server.addObject(BacnetObjectType.analogInput, 1);
  ///
  /// // Add Binary Value object instance 5
  /// await server.addObject(BacnetObjectType.binaryValue, 5);
  /// ```
  Future<void> addObject(int objectType, int instance) async {
    await _system.send(AddObjectRequest(objectType, instance));
  }

  /// Disposes of the server and releases resources.
  ///
  /// Stops the worker isolate and closes event streams.
  /// The server cannot be used after calling dispose.
  void dispose() {
    _system.dispose();
  }
}
