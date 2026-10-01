/// @docImport '../client/bacnet_client.dart';
/// @docImport '../server/bacnet_server.dart';
/// @docImport 'bacnet_config.dart';
library;

import '../constants/errors.dart';

/// Base exception class for BACnet operations.
///
/// All BACnet-specific exceptions extend this class.
class BacnetException implements Exception {
  /// Creates a BACnet exception with the given message.
  const BacnetException(this.message);

  /// Human-readable error message.
  final String message;

  @override
  String toString() => 'BacnetException: $message';
}

/// Exception thrown when a BACnet operation times out.
///
/// Thrown when a device does not answer after all APDU retries, or when the
/// overall request deadline (queueing included) expires.
class BacnetTimeoutException extends BacnetException {
  /// Creates a timeout exception.
  const BacnetTimeoutException(super.message);

  @override
  String toString() => 'BacnetTimeoutException: $message';
}

/// Exception thrown when the BACnet system is not initialized.
///
/// Operations cannot be performed until [BacnetClient.start] or
/// [BacnetServer.start] is called.
class BacnetNotInitializedException extends BacnetException {
  /// Creates a not initialized exception.
  const BacnetNotInitializedException([
    super.message = 'BACnet system not initialized. Call start() first.',
  ]);

  @override
  String toString() => 'BacnetNotInitializedException: $message';
}

/// Exception thrown when a BACnet Error PDU is received.
///
/// Contains the error class and code from the BACnet protocol, see
/// [BacnetErrorClass] and [BacnetErrorCode].
class BacnetProtocolException extends BacnetException {
  /// Creates a protocol exception with error details.
  const BacnetProtocolException(
    super.message, {
    required this.errorClass,
    required this.errorCode,
  });

  /// BACnet error class.
  final BacnetErrorClass errorClass;

  /// BACnet error code.
  final BacnetErrorCode errorCode;

  @override
  String toString() =>
      'BacnetProtocolException: $message '
      '(${BacnetErrorClass.getName(errorClass)}: '
      '${BacnetErrorCode.getName(errorCode)})';
}

/// Exception thrown when a device rejects a request (Reject PDU).
class BacnetRejectException extends BacnetException {
  /// Creates a reject exception.
  const BacnetRejectException(super.message, {required this.reason});

  /// BACnet reject reason.
  final BacnetRejectReason reason;

  @override
  String toString() =>
      'BacnetRejectException: $message (${BacnetRejectReason.getName(reason)})';
}

/// Exception thrown when a transaction is aborted (Abort PDU).
class BacnetAbortException extends BacnetException {
  /// Creates an abort exception.
  const BacnetAbortException(
    super.message, {
    required this.reason,
    this.fromServer = true,
  });

  /// BACnet abort reason.
  final BacnetAbortReason reason;

  /// True when the device aborted, false when aborted locally.
  final bool fromServer;

  /// True when the answer did not fit into one APDU.
  bool get isSegmentationNotSupported =>
      reason == BacnetAbortReason.segmentationNotSupported ||
      reason == BacnetAbortReason.bufferOverflow ||
      reason == BacnetAbortReason.apduTooLong;

  @override
  String toString() =>
      'BacnetAbortException: $message (${BacnetAbortReason.getName(reason)})';
}

/// Exception thrown when a device address cannot be resolved (no I-Am).
class BacnetDeviceNotFoundException extends BacnetException {
  /// Creates a device not found exception.
  const BacnetDeviceNotFoundException(super.message, {required this.deviceId});

  /// The device instance that could not be bound.
  final int deviceId;

  @override
  String toString() => 'BacnetDeviceNotFoundException: $message';
}

/// Exception thrown for requests to a device that stopped answering.
///
/// After [BacnetConfig.offlineAfterTimeouts] consecutive timeouts a device
/// is considered offline: requests fail immediately instead of occupying
/// transaction slots until they time out. After [retryAfter] one request
/// probes the device again; an I-Am from the device ends the offline state
/// at once. It is a [BacnetTimeoutException], so timeout handlers catch it.
class BacnetDeviceOfflineException extends BacnetTimeoutException {
  /// Creates a device offline exception.
  const BacnetDeviceOfflineException(
    super.message, {
    required this.deviceId,
    required this.retryAfter,
  });

  /// The device that stopped answering.
  final int deviceId;

  /// Time until the device is probed again.
  final Duration retryAfter;

  @override
  String toString() => 'BacnetDeviceOfflineException: $message';
}

/// Exception thrown when a request is cancelled with a `BacnetCancelToken`.
class BacnetCancelledException extends BacnetException {
  /// Creates a cancelled exception.
  const BacnetCancelledException([super.message = 'request cancelled']);

  @override
  String toString() => 'BacnetCancelledException: $message';
}

/// Exception thrown when the request queue is full (back pressure).
///
/// Raise [BacnetConfig.maxQueuedRequests] or slow down the producer.
class BacnetQueueFullException extends BacnetException {
  /// Creates a queue full exception.
  const BacnetQueueFullException(super.message);

  @override
  String toString() => 'BacnetQueueFullException: $message';
}

/// Exception thrown when received data cannot be decoded.
class BacnetDecodeException extends BacnetException {
  /// Creates a decode exception.
  const BacnetDecodeException(super.message);

  @override
  String toString() => 'BacnetDecodeException: $message';
}

/// Exception thrown when a value cannot be encoded.
class BacnetEncodeException extends BacnetException {
  /// Creates an encode exception.
  const BacnetEncodeException(super.message);

  @override
  String toString() => 'BacnetEncodeException: $message';
}
