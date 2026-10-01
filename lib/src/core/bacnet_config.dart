import '../models/bacnet_object.dart';
import 'logger.dart';
import 'types.dart';

/// Configuration of the BACnet stack shared by [BacnetClient] and
/// [BacnetServer].
///
/// The defaults suit a supervisory client talking to hundreds of devices;
/// tune the concurrency limits for very large or very slow networks.
///
/// Example:
/// ```dart
/// final client = BacnetClient(
///   config: const BacnetConfig(
///     interface: '192.168.1.100',
///     maxConcurrentRequests: 200,
///     maxConcurrentRequestsPerDevice: 4,
///     requestTimeout: Duration(seconds: 30),
///   ),
/// );
/// ```
class BacnetConfig {
  /// Creates a BACnet configuration.
  const BacnetConfig({
    this.interface,
    this.port = defaultPort,
    this.deviceInstance = BacnetObject.maxInstance,
    this.requestTimeout = defaultRequestTimeout,
    this.maxRetries = defaultMaxRetries,
    this.apduTimeout = defaultApduTimeout,
    this.maxConcurrentRequests = 200,
    this.maxConcurrentRequestsPerDevice = 4,
    this.maxQueuedRequests = 10000,
    this.bindTimeout = const Duration(seconds: 5),
    this.socketBufferSize = 4 * 1024 * 1024,
    this.strictSourceCheck = true,
    this.covScanInterval = const Duration(milliseconds: 50),
    this.idlePollInterval = const Duration(milliseconds: 20),
    this.logLevel = BacnetLogLevel.info,
    this.logger = const DeveloperBacnetLogger(),
  }) : assert(maxConcurrentRequests > 0 && maxConcurrentRequests <= 250),
       assert(maxConcurrentRequestsPerDevice > 0),
       assert(maxQueuedRequests > 0);

  /// Default BACnet/IP port number (0xBAC0).
  static const int defaultPort = 47808;

  /// Default overall request timeout (queueing and retries included).
  static const Duration defaultRequestTimeout = Duration(seconds: 30);

  /// Default APDU timeout of a single transmission.
  static const Duration defaultApduTimeout = Duration(seconds: 3);

  /// Default number of APDU retries.
  static const int defaultMaxRetries = 3;

  /// Network interface to bind to: interface name (`eth0`) or IPv4 address
  /// (`192.168.1.100`). `null` selects the first active interface.
  ///
  /// On Windows only IPv4 addresses are supported.
  final String? interface;

  /// UDP port for BACnet/IP.
  final int port;

  /// Instance of the local Device object. Clients that never call
  /// [BacnetServer.init] can keep the default (unconfigured) instance.
  final int deviceInstance;

  /// Maximum time a request may take, including the time spent waiting in
  /// the request queue and all APDU retries.
  final Duration requestTimeout;

  /// Number of APDU retries before a request times out.
  final int maxRetries;

  /// Time to wait for an answer before a request is retransmitted.
  final Duration apduTimeout;

  /// Maximum number of outstanding confirmed requests (all devices).
  ///
  /// Bounded by the 255 invoke ids of the BACnet transaction state machine.
  final int maxConcurrentRequests;

  /// Maximum number of outstanding confirmed requests per device.
  ///
  /// Small embedded controllers (and MS/TP devices behind routers) answer
  /// few requests at a time; flooding them causes aborts and timeouts.
  final int maxConcurrentRequestsPerDevice;

  /// Maximum number of queued requests before new requests fail fast with
  /// [BacnetQueueFullException] (back pressure).
  final int maxQueuedRequests;

  /// Time to wait for an I-Am when a request targets a device whose address
  /// is unknown. The client sends targeted Who-Is requests in the meantime.
  final Duration bindTimeout;

  /// Socket send/receive buffer size in bytes (0 keeps the OS default).
  /// Large buffers avoid packet loss during I-Am storms and bursts.
  final int socketBufferSize;

  /// Ignore replies whose source address differs from the request target.
  /// Prevents late replies with recycled invoke ids from completing the
  /// wrong request.
  final bool strictSourceCheck;

  /// Interval of the server side Change-of-Value detection scan.
  final Duration covScanInterval;

  /// Maximum time the worker blocks waiting for network traffic when idle.
  final Duration idlePollInterval;

  /// Minimum level of messages forwarded from the worker isolate.
  final BacnetLogLevel logLevel;

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
    int? deviceInstance,
    Duration? requestTimeout,
    int? maxRetries,
    Duration? apduTimeout,
    int? maxConcurrentRequests,
    int? maxConcurrentRequestsPerDevice,
    int? maxQueuedRequests,
    Duration? bindTimeout,
    int? socketBufferSize,
    bool? strictSourceCheck,
    Duration? covScanInterval,
    Duration? idlePollInterval,
    BacnetLogLevel? logLevel,
    BacnetLogger? logger,
  }) {
    return BacnetConfig(
      interface: interface ?? this.interface,
      port: port ?? this.port,
      deviceInstance: deviceInstance ?? this.deviceInstance,
      requestTimeout: requestTimeout ?? this.requestTimeout,
      maxRetries: maxRetries ?? this.maxRetries,
      apduTimeout: apduTimeout ?? this.apduTimeout,
      maxConcurrentRequests:
          maxConcurrentRequests ?? this.maxConcurrentRequests,
      maxConcurrentRequestsPerDevice:
          maxConcurrentRequestsPerDevice ?? this.maxConcurrentRequestsPerDevice,
      maxQueuedRequests: maxQueuedRequests ?? this.maxQueuedRequests,
      bindTimeout: bindTimeout ?? this.bindTimeout,
      socketBufferSize: socketBufferSize ?? this.socketBufferSize,
      strictSourceCheck: strictSourceCheck ?? this.strictSourceCheck,
      covScanInterval: covScanInterval ?? this.covScanInterval,
      idlePollInterval: idlePollInterval ?? this.idlePollInterval,
      logLevel: logLevel ?? this.logLevel,
      logger: logger ?? this.logger,
    );
  }

  @override
  String toString() {
    return 'BacnetConfig('
        'interface: $interface, '
        'port: $port, '
        'device: $deviceInstance, '
        'timeout: ${requestTimeout.inMilliseconds}ms, '
        'apduTimeout: ${apduTimeout.inMilliseconds}ms, '
        'retries: $maxRetries, '
        'concurrency: $maxConcurrentRequests/$maxConcurrentRequestsPerDevice, '
        'queue: $maxQueuedRequests'
        ')';
  }
}
