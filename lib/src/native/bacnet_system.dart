import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../core/exceptions.dart';
import '../core/logger.dart';
import '../core/types.dart';
import '../models/internal/worker_message.dart';
import '../models/rpm_models.dart';
import '../models/wpm_models.dart';
import 'worker/entry_point.dart';

/// Low-level BACnet system interface managing the worker isolate.
///
/// This singleton class manages communication with the BACnet worker isolate,
/// handles request-response matching, and provides event streaming for
/// unsolicited messages like I-Am and COV notifications.
class BacnetSystem {
  static final BacnetSystem _instance = BacnetSystem._internal();

  /// Gets the singleton instance of BacnetSystem.
  static BacnetSystem get instance => _instance;

  BacnetSystem._internal();

  Isolate? _workerIsolate;
  SendPort? _workerSendPort;
  Completer<void> _initCompleter = Completer<void>();
  StreamController<dynamic> _eventController =
      StreamController<dynamic>.broadcast();

  final Map<int, Completer<dynamic>> _pendingRequests = {};
  int _trackingIdCounter = 0;
  final Map<int, int> _invokeToTrackingMap = {};

  BacnetLogger _logger = const DeveloperBacnetLogger();

  /// Sets the logger for BACnet system messages.
  void setLogger(BacnetLogger logger) {
    _logger = logger;
  }

  /// Logs a message using the configured logger.
  void log(
    BacnetLogLevel level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    _logger.log(level, message, error, stackTrace);
  }

  /// Stream of unsolicited events from the BACnet network.
  ///
  /// Includes I-Am responses, COV notifications, and write notifications.
  Stream<dynamic> get events => _eventController.stream;

  /// Starts the BACnet worker isolate and initializes the BACnet stack.
  ///
  /// [interface] - Optional network interface name to bind to.
  /// [port] - UDP port to listen on (default 47808).
  Future<void> start({String? interface, int port = 47808}) async {
    // Idempotent: if already started, just return
    if (_workerIsolate != null) {
      return;
    }

    // Recreate completer and event controller if disposed
    if (_initCompleter.isCompleted) {
      _initCompleter = Completer<void>();
    }
    if (_eventController.isClosed) {
      _eventController = StreamController<dynamic>.broadcast();
    }

    final receivePort = ReceivePort();
    _workerIsolate = await Isolate.spawn(bacnetWorkerEntryPoint, {
      'sendPort': receivePort.sendPort,
      'interface': interface,
      'port': port,
    }, debugName: 'BacnetWorker');

    receivePort.listen((message) {
      if (message is SendPort) {
        _workerSendPort = message;
        if (!_initCompleter.isCompleted) {
          _initCompleter.complete();
        }
      } else if (message is WorkerResponse) {
        _handleWorkerMessage(message);
      }
    });
  }

  void _handleWorkerMessage(WorkerResponse message) {
    if (message is ErrorResponse) {
      if (!_initCompleter.isCompleted) {
        _initCompleter.completeError(message.error);
      } else {
        _eventController.add(message);
      }
      return;
    }

    if (message is ReadPropertySentResponse) {
      _invokeToTrackingMap[message.invokeId] = message.trackingId;
    } else if (message is ReadPropertyAckResponse) {
      final trackingId = _invokeToTrackingMap.remove(message.invokeId);
      if (trackingId != null) {
        final completer = _pendingRequests.remove(trackingId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(message.value);
        }
      }
      _eventController.add(message);
    } else if (message is ReadRangeAckResponse) {
      final trackingId = _invokeToTrackingMap.remove(message.invokeId);
      if (trackingId != null) {
        final completer = _pendingRequests.remove(trackingId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(message);
        }
      }
      _eventController.add(message);
    } else if (message is ReadPropertyMultipleAckResponse) {
      final trackingId = _invokeToTrackingMap.remove(message.invokeId);
      if (trackingId != null) {
        final completer = _pendingRequests.remove(trackingId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(message.values);
        }
      }
      _eventController.add(message);
    } else if (message is LogResponse) {
      // Also print to console for debugging
      debugPrint('[Worker] ${message.message}');
      _logger.log(
        BacnetLogLevel.values[message.levelIndex],
        message.message,
        message.errorObj,
        message.stackTrace != null
            ? StackTrace.fromString(message.stackTrace!)
            : null,
      );
    } else {
      _eventController.add(message);
    }
  }

  /// Sends a request to the worker isolate.
  Future<void> send(WorkerRequest request) async {
    await _initCompleter.future;
    _workerSendPort?.send(request);
  }

  /// Sends a ReadProperty request and waits for the response.
  Future<dynamic> sendReadProperty(
    int deviceId,
    int objectType,
    int instance,
    int propertyId, {
    int arrayIndex = -1,
  }) async {
    await _initCompleter.future;
    final trackingId = ++_trackingIdCounter;
    final completer = Completer<dynamic>();
    _pendingRequests[trackingId] = completer;

    _workerSendPort?.send(
      ReadPropertyRequest(
        trackingId: trackingId,
        deviceId: deviceId,
        objectType: objectType,
        instance: instance,
        propertyId: propertyId,
        arrayIndex: arrayIndex,
      ),
    );

    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pendingRequests.remove(trackingId);
        throw const BacnetTimeoutException('ReadProperty timed out');
      },
    );
  }

  /// Sends a ReadPropertyMultiple request and waits for the response.
  Future<Map<String, Map<int, dynamic>>> sendReadPropertyMultiple(
    int deviceId,
    List<BacnetReadAccessSpecification> specs,
  ) async {
    debugPrint('🟢 Main: sendReadPropertyMultiple called for device $deviceId');
    debugPrint(
      '🟢 Main: _workerSendPort is ${_workerSendPort == null ? "NULL" : "not null"}',
    );

    await _initCompleter.future;
    final trackingId = ++_trackingIdCounter;
    // The native layer returns a complex Map structure for RPM
    final completer = Completer<Map<String, Map<int, dynamic>>>();
    _pendingRequests[trackingId] = completer;

    debugPrint('🟢 Main: Sending RPM to worker (trackingId: $trackingId)');

    _workerSendPort?.send(
      ReadPropertyMultipleRequest(
        trackingId: trackingId,
        deviceId: deviceId,
        readAccessSpecs: specs,
      ),
    );

    debugPrint('🟢 Main: RPM request sent to worker');

    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pendingRequests.remove(trackingId);
        throw const BacnetTimeoutException('ReadPropertyMultiple timed out');
      },
    );
  }

  /// Sends a WritePropertyMultiple request.
  Future<void> sendWritePropertyMultiple(
    int deviceId,
    List<BacnetWriteAccessSpecification> specs, {
    int? trackingId,
  }) async {
    await send(
      WritePropertyMultipleRequest(
        deviceId: deviceId,
        writeAccessSpecs: specs,
        trackingId: trackingId,
      ),
    );
  }

  /// Sends a ReadRange request.
  Future<ReadRangeAckResponse> sendReadRange(
    int deviceId, {
    required int objectType,
    required int instance,
    required int propertyId,
    int arrayIndex = -1,
    int requestType = 1, // RR_BY_POSITION
    dynamic reference = 1, // Start index 1
    int count = 0,
  }) async {
    await _initCompleter.future;
    final trackingId = ++_trackingIdCounter;
    final completer = Completer<dynamic>();
    _pendingRequests[trackingId] = completer;

    _workerSendPort?.send(
      ReadRangeRequest(
        deviceId: deviceId,
        objectType: objectType,
        instance: instance,
        propertyId: propertyId,
        arrayIndex: arrayIndex,
        requestType: requestType,
        reference: reference,
        count: count,
        trackingId: trackingId,
      ),
    );

    final response = await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pendingRequests.remove(trackingId);
        throw const BacnetTimeoutException('ReadRange timed out');
      },
    );

    if (response is ReadRangeAckResponse) {
      return response;
    } else {
      throw BacnetException('Unexpected response: $response');
    }
  }

  /// Stops the worker isolate and cleans up resources.
  void dispose() {
    _workerIsolate?.kill(priority: Isolate.immediate);
    _workerIsolate = null;
    _workerSendPort = null;

    // Close current event controller
    _eventController.close();

    // Clear pending requests
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError('BacnetSystem disposed');
      }
    }
    _pendingRequests.clear();
    _invokeToTrackingMap.clear();
  }
}
