// ignore_for_file: avoid_print
import 'dart:developer' as developer;

import 'types.dart';

/// Abstract logger interface for BACnet operations.
///
/// Allows pluggable logging implementations to be used throughout
/// the plugin. Users can provide custom implementations by implementing
/// this interface.
abstract class BacnetLogger {
  /// Logs a message with the given level.
  ///
  /// [level] specifies the severity of the log message.
  /// [message] is the log message text.
  /// [error] is an optional error object.
  /// [stackTrace] is an optional stack trace for debugging.
  void log(
    BacnetLogLevel level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]);
}

/// Console-based logger implementation using print statements.
///
/// This is the default logger for backward compatibility.
/// For production use, consider using [DeveloperBacnetLogger] instead.
class ConsoleBacnetLogger implements BacnetLogger {
  /// Creates a console-based logger.
  const ConsoleBacnetLogger();

  @override
  void log(
    BacnetLogLevel level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    final timestamp = DateTime.now().toIso8601String();
    final prefix = '[${level.name.toUpperCase()}] $timestamp:';
    print('$prefix $message');
    if (error != null) {
      print('  Error: $error');
    }
    if (stackTrace != null) {
      print('  StackTrace: $stackTrace');
    }
  }
}

/// Structured logger using dart:developer that integrates with Dart DevTools.
///
/// This logger uses the official Dart logging API which provides better
/// integration with debugging tools and allows filtering logs by name
/// and severity level in DevTools.
///
/// Example usage:
/// ```dart
/// final client = BacnetClient(logger: const DeveloperBacnetLogger());
/// ```
class DeveloperBacnetLogger implements BacnetLogger {
  /// Creates a developer tools logger.
  ///
  /// [name] is the logger name that appears in DevTools (default: 'bacnet_plugin').
  const DeveloperBacnetLogger({this.name = 'bacnet_plugin'});

  /// The name shown in DevTools for this logger.
  final String name;

  @override
  void log(
    BacnetLogLevel level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    developer.log(
      message,
      name: name,
      level: _getLevelValue(level),
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Converts BacnetLogLevel to dart:developer log level values.
  int _getLevelValue(BacnetLogLevel level) {
    switch (level) {
      case BacnetLogLevel.debug:
        return 500; // FINE
      case BacnetLogLevel.info:
        return 800; // INFO
      case BacnetLogLevel.warning:
        return 900; // WARNING
      case BacnetLogLevel.error:
        return 1000; // SEVERE
    }
  }
}
