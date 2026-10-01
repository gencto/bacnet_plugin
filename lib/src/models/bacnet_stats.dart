import 'package:meta/meta.dart';

/// Runtime statistics of the BACnet engine, for monitoring and tuning.
@immutable
class BacnetStats {
  /// Creates statistics.
  const BacnetStats({
    required this.queuedRequests,
    required this.inFlightRequests,
    required this.completedRequests,
    required this.failedRequests,
    required this.timeouts,
    required this.packetsReceived,
    required this.requestsSent,
    required this.repliesDropped,
    required this.eventsDropped,
    required this.boundDevices,
    required this.bindingDevices,
    this.offlineDevices = 0,
    this.segmentedReplies = 0,
    required this.freeTransactions,
    required this.pollCalls,
  });

  /// Requests waiting for a free transaction slot or a device binding.
  final int queuedRequests;

  /// Confirmed requests waiting for an answer.
  final int inFlightRequests;

  /// Confirmed requests completed successfully.
  final int completedRequests;

  /// Confirmed requests that failed (errors, rejects, aborts, timeouts).
  final int failedRequests;

  /// Requests that timed out after all retries.
  final int timeouts;

  /// Packets received by the datalink.
  final int packetsReceived;

  /// Requests sent (confirmed and unconfirmed).
  final int requestsSent;

  /// Replies dropped because their source did not match the request.
  final int repliesDropped;

  /// Native events dropped because the event buffer was full.
  final int eventsDropped;

  /// Devices with a known address.
  final int boundDevices;

  /// Devices whose address is being resolved.
  final int bindingDevices;

  /// Devices considered offline after consecutive timeouts.
  final int offlineDevices;

  /// Answers received in segments and reassembled.
  final int segmentedReplies;

  /// Idle transaction state machine slots.
  final int freeTransactions;

  /// Worker poll iterations.
  final int pollCalls;

  @override
  String toString() =>
      'BacnetStats(queued: $queuedRequests, '
      'inFlight: $inFlightRequests, completed: $completedRequests, '
      'failed: $failedRequests, timeouts: $timeouts, '
      'rx: $packetsReceived, tx: $requestsSent, '
      'droppedReplies: $repliesDropped, droppedEvents: $eventsDropped, '
      'bound: $boundDevices, binding: $bindingDevices, '
      'offline: $offlineDevices, segmented: $segmentedReplies, '
      'freeTsm: $freeTransactions)';
}
