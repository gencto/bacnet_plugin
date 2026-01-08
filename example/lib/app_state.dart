import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter/foundation.dart';

/// Application state management for BACnet client operations.
///
/// Manages the BACnet client lifecycle, device discovery, and error states.
class AppState extends ChangeNotifier {
  AppState() {
    _client = BacnetClient();
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
  Future<void> startClient({String? interface}) async {
    try {
      _errorMessage = null;
      notifyListeners();

      await _client.start(interface: interface);
      _isStarted = true;
      notifyListeners();
    } on Exception catch (e) {
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
      notifyListeners();
      return;
    }

    try {
      _isScanning = true;
      _errorMessage = null;
      notifyListeners();

      final scanner = DeviceScanner(_client);
      _devices = await scanner.discoverDevices(timeout: timeout);

      _isScanning = false;
      notifyListeners();
    } on Exception catch (e) {
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
