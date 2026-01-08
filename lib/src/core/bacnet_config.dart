import 'logger.dart';

/// Configuration options for BACnet client and server operations.
///
/// This class encapsulates all configuration parameters needed to
/// initialize and operate BACnet communication. Use [copyWith] to
/// create modified configurations.
///
/// Example:
/// ```dart
/// final config = BacnetConfig(
///   interface: '192.168.1.100',
///   port: 47808,
///   requestTimeout: Duration(seconds: 10),
///   logger: DeveloperBacnetLogger(),
/// );
/// ```
class BacnetConfig {
  /// Creates a BACnet configuration.
  const BacnetConfig({
    this.interface,
    this.port = defaultPort,
    this.requestTimeout = defaultRequestTimeout,
    this.maxRetries = defaultMaxRetries,
    this.logger = const DeveloperBacnetLogger(),
  });

  /// Default BACnet/IP port number.
  static const int defaultPort = 47808;

  /// Default request timeout duration.
  static const Duration defaultRequestTimeout = Duration(seconds: 5);

  /// Default maximum number of retries for failed requests.
  static const int defaultMaxRetries = 3;

  /// Network interface to bind to (null for all interfaces).
  ///
  /// Can be an IP address like '192.168.1.100' or null to bind
  /// to all available network interfaces.
  final String? interface;

  /// UDP port for BACnet communication.
  ///
  /// Standard BACnet port is 47808 (0xBAC0).
  final int port;

  /// Maximum time to wait for a response before timing out.
  final Duration requestTimeout;

  /// Maximum number of retry attempts for failed requests.
  final int maxRetries;

  /// Logger implementation for BACnet operations.
  ///
  /// Defaults to [DeveloperBacnetLogger]. Use [ConsoleBacnetLogger]
  /// for simple terminal output.
  final BacnetLogger logger;

  /// Creates a copy of this configuration with updated values.
  ///
  /// Any parameters not specified will use the values from this configuration.
  BacnetConfig copyWith({
    String? interface,
    int? port,
    Duration? requestTimeout,
    int? maxRetries,
    BacnetLogger? logger,
  }) {
    return BacnetConfig(
      interface: interface ?? this.interface,
      port: port ?? this.port,
      requestTimeout: requestTimeout ?? this.requestTimeout,
      maxRetries: maxRetries ?? this.maxRetries,
      logger: logger ?? this.logger,
    );
  }

  @override
  String toString() {
    return 'BacnetConfig('
        'interface: $interface, '
        'port: $port, '
        'timeout: ${requestTimeout.inSeconds}s, '
        'retries: $maxRetries'
        ')';
  }
}
