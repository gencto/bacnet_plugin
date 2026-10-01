/// @docImport 'logger.dart';
library;

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
