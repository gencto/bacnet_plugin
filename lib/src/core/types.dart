/// Log level enumeration for BACnet operations.
///
/// Used by [BacnetLogger] implementations to categorize log messages.
enum BacnetLogLevel {
  /// Debug-level messages for detailed troubleshooting.
  debug,

  /// Informational messages about normal operations.
  info,

  /// Warning messages for potential issues.
  warning,

  /// Error messages for failures.
  error,
}

/// Represents a BACnet protocol error.
///
/// Contains the error class and error code as defined in the BACnet standard.
/// Use [BacnetErrorClass] and [BacnetErrorCode] constants for interpreting values.
class BacnetError {
  /// Creates a BACnet error.
  const BacnetError(this.errorClass, this.errorCode);

  /// The error class (e.g., device, object, property).
  final int errorClass;

  /// The specific error code within the error class.
  final int errorCode;

  @override
  String toString() => 'BacnetError(class: $errorClass, code: $errorCode)';
}
