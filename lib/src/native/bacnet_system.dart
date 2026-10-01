import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/bacnet_config.dart';
import '../core/exceptions.dart';
import '../core/logger.dart';
import '../core/types.dart';
import '../models/bacnet_stats.dart';
import '../models/internal/worker_message.dart';
import 'bindings.g.dart' show bacnet_plugin_wakeup;
import 'protocol.dart';
import 'worker.dart';

/// Low-level BACnet system interface managing the worker isolate.
///
/// The bacnet-stack is process global, so one [BacnetSystem] (and one
/// worker isolate) serves every [BacnetClient] and [BacnetServer] of the
/// process. [start] and [release] are reference counted.
class BacnetSystem {
  BacnetSystem._internal();

  static final BacnetSystem _instance = BacnetSystem._internal();

  /// Gets the singleton instance of BacnetSystem.
  static BacnetSystem get instance => _instance;

  BacnetConfig _config = const BacnetConfig();
  BacnetLogger? _loggerOverride;
  int _references = 0;
  Future<void>? _starting;
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _responses;
  ReceivePort? _exitPort;
  String? _version;
  Completer<void>? _exited;

  int _nextId = 0;
  final Map<int, Completer<Object?>> _pending = {};

  StreamController<WorkerResponse> _events =
      StreamController<WorkerResponse>.broadcast(sync: true);

  /// Active configuration.
  BacnetConfig get config => _config;

  /// True while the worker isolate is running.
  bool get isRunning => _commands != null;

  /// Version of the native engine and bacnet-stack.
  String? get nativeVersion => _version;

  /// Number of requests awaiting an answer from the worker.
  int get pendingCommands => _pending.length;

  BacnetLogger get _logger => _loggerOverride ?? _config.logger;

  /// Sets the logger for BACnet system messages.
  void setLogger(BacnetLogger logger) {
    _loggerOverride = logger;
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

  /// Stream of unsolicited events (I-Am, COV, writes, logs, errors).
  Stream<WorkerResponse> get events => _events.stream;

  /// Starts the worker isolate and initializes the BACnet stack. When the
  /// stack is already running the call only takes a reference; the first
  /// caller's configuration wins.
  Future<void> start(BacnetConfig config) async {
    _references++;
    try {
      if (_commands != null) return;
      if (_starting != null) {
        await _starting;
        return;
      }
      _config = config;
      final starting = _spawn(config);
      _starting = starting;
      try {
        await starting;
      } finally {
        _starting = null;
      }
    } on Object {
      _references--;
      rethrow;
    }
  }

  Future<void> _spawn(BacnetConfig config) async {
    if (_events.isClosed) {
      _events = StreamController<WorkerResponse>.broadcast(sync: true);
    }
    final responses = ReceivePort('BacnetWorkerResponses');
    final exitPort = ReceivePort('BacnetWorkerExit');
    final ready = Completer<void>();
    final exited = Completer<void>();
    _responses = responses;
    _exitPort = exitPort;
    _exited = exited;

    responses.listen((Object? message) {
      if (message is List) {
        for (final item in message) {
          _onMessage(item);
        }
      } else if (message is WorkerReady) {
        _commands = message.commandPort;
        _version = message.version;
        if (!ready.isCompleted) ready.complete();
      } else if (message is WorkerFailed) {
        if (!ready.isCompleted) {
          ready.completeError(BacnetException(message.message));
        }
      }
    });
    exitPort.listen((_) {
      if (!ready.isCompleted) {
        ready.completeError(
          const BacnetException('BACnet worker exited during startup'),
        );
      }
      _onWorkerExit();
    });

    final startup = WorkerStartup(
      mainPort: responses.sendPort,
      interface: config.interface,
      port: config.port,
      deviceInstance: config.deviceInstance,
      apduTimeoutMs: config.apduTimeout.inMilliseconds,
      apduRetries: config.maxRetries,
      socketBufferSize: config.socketBufferSize,
      strictSourceCheck: config.strictSourceCheck,
      covScanIntervalMs: config.covScanInterval.inMilliseconds.clamp(1, 60000),
      idlePollMs: config.idlePollInterval.inMilliseconds.clamp(1, 1000),
      maxInFlight: config.maxConcurrentRequests,
      maxInFlightPerDevice: config.maxConcurrentRequestsPerDevice,
      maxQueued: config.maxQueuedRequests,
      bindTimeoutMs: config.bindTimeout.inMilliseconds,
      logLevel: config.logLevel,
    );
    try {
      _isolate = await Isolate.spawn(
        bacnetWorkerMain,
        startup,
        debugName: 'BacnetWorker',
        onExit: exitPort.sendPort,
        errorsAreFatal: false,
      );
      await ready.future;
    } on Object {
      _isolate?.kill(priority: Isolate.immediate);
      _cleanupPorts();
      rethrow;
    }
  }

  void _onMessage(Object? message) {
    switch (message) {
      case CommandResult(:final id, :final value):
        _pending.remove(id)?.complete(value);
      case CommandFailure(:final id, :final error):
        _pending.remove(id)?.completeError(error);
      case LogResponse():
        _logger.log(
          BacnetLogLevel.values[message.levelIndex],
          message.message,
          message.errorObj,
          message.stackTrace == null
              ? null
              : StackTrace.fromString(message.stackTrace!),
        );
        if (_events.hasListener) _events.add(message);
      case WorkerResponse():
        if (_events.hasListener) _events.add(message);
    }
  }

  void _onWorkerExit() {
    final exited = _exited;
    if (exited != null && !exited.isCompleted) exited.complete();
    final wasRunning = _commands != null;
    _commands = null;
    _isolate = null;
    _cleanupPorts();
    const error = BacnetException('BACnet worker stopped');
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
    if (wasRunning && _references > 0 && _events.hasListener) {
      _events.add(const ErrorResponse('BACnet worker stopped unexpectedly'));
    }
  }

  void _cleanupPorts() {
    _responses?.close();
    _exitPort?.close();
    _responses = null;
    _exitPort = null;
  }

  /// Sends [build]'s command to the worker and waits for its result.
  ///
  /// [timeout] is a safety net on top of the worker side deadlines.
  Future<T> call<T>(WorkerCommand Function(int id) build, {Duration? timeout}) {
    final commands = _commands;
    if (commands == null) {
      return Future<T>.error(const BacnetNotInitializedException());
    }
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    commands.send(build(id));
    bacnet_plugin_wakeup();
    var future = completer.future;
    if (timeout != null) {
      future = future.timeout(
        timeout,
        onTimeout: () {
          _pending.remove(id);
          throw BacnetTimeoutException(
            'no answer from the BACnet worker within $timeout',
          );
        },
      );
    }
    return future.then((value) => value as T);
  }

  /// Sends a confirmed request and returns the decoded answer.
  Future<Object?> confirmed({
    required int deviceId,
    required int service,
    required Uint8List payload,
    AckDecoding decoding = AckDecoding.none,
    Duration? timeout,
  }) {
    final effective = timeout ?? _config.requestTimeout;
    return call<Object?>(
      (id) => ConfirmedRequestCommand(
        id,
        deviceId: deviceId,
        service: service,
        payload: payload,
        timeoutMs: effective.inMilliseconds,
        decoding: decoding,
      ),
      // the worker enforces the deadline; this only guards a dead worker
      timeout: effective + const Duration(seconds: 5),
    );
  }

  /// Returns runtime statistics of the engine.
  Future<BacnetStats> stats() => call<BacnetStats>(StatsCommand.new);

  /// Releases one reference; the worker stops with the last one.
  Future<void> release() async {
    if (_references == 0) return;
    _references--;
    if (_references > 0) return;
    await _stop();
  }

  Future<void> _stop() async {
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // startup failed: nothing to stop
      }
    }
    if (_commands == null) return;
    final exited = _exited;
    try {
      await call<void>(
        ShutdownCommand.new,
        timeout: const Duration(seconds: 5),
      );
    } on Object {
      _isolate?.kill(priority: Isolate.immediate);
    }
    // wait for the isolate to exit so that a restart can bind the port again
    if (exited != null) {
      await exited.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _isolate?.kill(priority: Isolate.immediate);
          _onWorkerExit();
        },
      );
    }
  }

  /// Stops the worker isolate immediately, regardless of references.
  void dispose() {
    _references = 0;
    if (_commands != null) {
      unawaited(_stop());
    }
  }
}
