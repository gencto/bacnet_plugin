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
/// This typically occurs when a device does not respond within
/// the configured timeout period.
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
}

/// Exception thrown when a BACnet protocol error is received.
///
/// Contains the error class and code from the BACnet protocol.
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
      'BacnetProtocolException: $message (class: $errorClass, code: $errorCode)';
}
