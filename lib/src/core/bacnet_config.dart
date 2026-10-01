/// @docImport '../client/bacnet_client.dart';
/// @docImport '../server/bacnet_server.dart';
/// @docImport 'exceptions.dart';
library;

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
    this.coalesceReads = true,
    this.maxCoalescedReads = 24,
    this.coalescingWindow = Duration.zero,
    this.bindTimeout = const Duration(seconds: 5),
    this.offlineAfterTimeouts = 3,
    this.offlineRetryInterval = const Duration(seconds: 30),
    this.maxSegmentsAccepted = 32,
    this.socketBufferSize = 4 * 1024 * 1024,
    this.strictSourceCheck = true,
    this.covScanInterval = const Duration(milliseconds: 50),
    this.idlePollInterval = const Duration(milliseconds: 20),
    this.logLevel = BacnetLogLevel.info,
    this.logger = const DeveloperBacnetLogger(),
  }) : assert(maxConcurrentRequests > 0 && maxConcurrentRequests <= 250),
       assert(maxConcurrentRequestsPerDevice > 0),
       assert(maxQueuedRequests > 0),
       assert(maxCoalescedReads > 0),
       assert(offlineAfterTimeouts >= 0),
       assert(maxSegmentsAccepted >= 0 && maxSegmentsAccepted <= 32);

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

  /// Merge concurrent [BacnetClient.readProperty] calls to the same device
  /// into ReadPropertyMultiple requests.
  ///
  /// Reads issued together (e.g. with `Future.wait`) then cost one request
  /// per device instead of one per property. Results and errors are the
  /// same as with single reads; devices without ReadPropertyMultiple
  /// support are detected and read one property at a time.
  final bool coalesceReads;

  /// Maximum number of properties per merged ReadPropertyMultiple request.
  ///
  /// Answers that do not fit into the device's APDU are split
  /// automatically, but each split costs a round trip: keep this low for
  /// devices with small APDUs (MS/TP: 480 bytes).
  final int maxCoalescedReads;

  /// Time to collect reads before a merged request is sent. Zero merges
  /// the reads issued in the same event loop turn.
  final Duration coalescingWindow;

  /// Time to wait for an I-Am when a request targets a device whose address
  /// is unknown. The client sends targeted Who-Is requests in the meantime.
  final Duration bindTimeout;

  /// Consecutive timeouts after which a device is considered offline;
  /// 0 disables it.
  ///
  /// Requests to an offline device fail immediately with
  /// [BacnetDeviceOfflineException] instead of occupying transaction slots
  /// until they time out, which keeps a dead controller from slowing down
  /// the rest of the site.
  final int offlineAfterTimeouts;

  /// Time an offline device is left alone before one request probes it
  /// again. Doubles (up to 8 times) while the device stays silent; an
  /// I-Am from the device ends the offline state immediately.
  final Duration offlineRetryInterval;

  /// Number of segments accepted in an answer (0 or 1 disables segmented
  /// answers, at most 32).
  ///
  /// Devices send answers that exceed their APDU size (large object lists,
  /// schedules, ReadPropertyMultiple results) in segments; they are
  /// reassembled transparently. Devices that cannot segment abort such
  /// requests instead, which the client handles by splitting
  /// ReadPropertyMultiple requests and reading arrays element by element.
  final int maxSegmentsAccepted;

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
    bool? coalesceReads,
    int? maxCoalescedReads,
    Duration? coalescingWindow,
    Duration? bindTimeout,
    int? offlineAfterTimeouts,
    Duration? offlineRetryInterval,
    int? maxSegmentsAccepted,
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
      coalesceReads: coalesceReads ?? this.coalesceReads,
      maxCoalescedReads: maxCoalescedReads ?? this.maxCoalescedReads,
      coalescingWindow: coalescingWindow ?? this.coalescingWindow,
      bindTimeout: bindTimeout ?? this.bindTimeout,
      offlineAfterTimeouts: offlineAfterTimeouts ?? this.offlineAfterTimeouts,
      offlineRetryInterval: offlineRetryInterval ?? this.offlineRetryInterval,
      maxSegmentsAccepted: maxSegmentsAccepted ?? this.maxSegmentsAccepted,
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
