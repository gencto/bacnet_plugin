import '../constants/error_codes.dart';

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
  final int errorClass;

  /// BACnet error code.
  final int errorCode;

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

  /// BACnet reject reason (see [BacnetRejectReason]).
  final int reason;

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

  /// BACnet abort reason (see [BacnetAbortReason]).
  final int reason;

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
