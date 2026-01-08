import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter/foundation.dart';

/// Application state management for BACnet client operations.
///
/// Manages the BACnet client lifecycle, device discovery, and error states.
class AppState extends ChangeNotifier {
  AppState() {
    // Enable logging to see what's happening
    _client = BacnetClient(logger: const DeveloperBacnetLogger());
  }

  late final BacnetClient _client;

  /// The BACnet client instance.
  BacnetClient get client => _client;

  /// List of discovered BACnet devices.
  List<DiscoveredDevice> _devices = [];
  List<DiscoveredDevice> get devices => List.unmodifiable(_devices);

  /// Whether a discovery scan is currently in progress.
  bool _isScanning = false;
  bool get isScanning => _isScanning;

  /// Whether the client has been started.
  bool _isStarted = false;
  bool get isStarted => _isStarted;

  /// Current error message, if any.
  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  /// Starts the BACnet client.
  ///
  /// Must be called before any other operations.
  Future<void> startClient({String? interface, int port = 47808}) async {
    debugPrint(
      '🚀 Starting BACnet client with interface: $interface, port: $port',
    );

    try {
      _errorMessage = null;
      notifyListeners();

      await _client.start(interface: interface, port: port);
      _isStarted = true;
      debugPrint('✅ BACnet client started successfully!');
      notifyListeners();
    } on Exception catch (e, stack) {
      debugPrint('❌ Failed to start BACnet client: $e');
      debugPrint('Stack trace: $stack');
      _errorMessage = 'Failed to start BACnet client: $e';
      _isStarted = false;
      notifyListeners();
      rethrow;
    }
  }

  /// Discovers BACnet devices on the network.
  ///
  /// Sends a Who-Is broadcast and collects I-Am responses.
  Future<void> discoverDevices({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!_isStarted) {
      _errorMessage = 'Client not started. Call startClient() first.';
      debugPrint('❌ Client not started!');
      notifyListeners();
      return;
    }

    try {
      _isScanning = true;
      _errorMessage = null;
      notifyListeners();

      debugPrint('📡 Creating DeviceScanner...');
      final scanner = DeviceScanner(_client);

      debugPrint('⏳ Waiting for devices (timeout: ${timeout.inSeconds}s)...');
      _devices = await scanner.discoverDevices(timeout: timeout);

      debugPrint('✅ Discovery completed! Found ${_devices.length} devices');
      for (var device in _devices) {
        debugPrint(
          '  - Device ${device.deviceId}: ${device.deviceName ?? "Unknown"}',
        );
      }

      _isScanning = false;
      notifyListeners();
    } on Exception catch (e, stack) {
      debugPrint('❌ Discovery failed: $e');
      debugPrint('Stack trace: $stack');
      _errorMessage = 'Discovery failed: $e';
      _isScanning = false;
      notifyListeners();
    }
  }

  /// Clears the current error message.
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// Clears the list of discovered devices.
  void clearDevices() {
    _devices = [];
    notifyListeners();
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }
}
