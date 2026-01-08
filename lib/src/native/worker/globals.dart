import 'dart:isolate';

import '../../../bacnet_plugin_bindings.g.dart';
import '../../core/types.dart';
import '../../models/internal/worker_message.dart';

/// Global instance of BACnet native bindings.
late BacnetBindings bindings;

/// SendPort for sending messages from worker isolate to main isolate.
SendPort? workerToMainSendPort;

/// Maximum APDU (Application Protocol Data Unit) size in bytes.
const int maxAPDU = 1476;

/// Sends a log message from the worker isolate to the main isolate.
///
/// This is the worker isolate's logging interface that forwards log messages
/// to the main isolate for proper logging framework integration.
void logToMain(
  BacnetLogLevel level,
  String message, [
  Object? error,
  StackTrace? stackTrace,
]) {
  workerToMainSendPort?.send(
    LogResponse(
      levelIndex: level.index,
      message: message,
      errorObj: error?.toString(),
      stackTrace: stackTrace?.toString(),
    ),
  );
}
