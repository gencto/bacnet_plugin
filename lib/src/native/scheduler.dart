import 'dart:collection';

import '../core/exceptions.dart';
import 'bindings.g.dart';
import 'native_errors.dart';
import 'protocol.dart';

/// Sends the requests released by a [RequestScheduler].
abstract interface class RequestTransport {
  /// Sends a confirmed request and returns its invoke id (> 0) or a
  /// negative native result code (`BP_ERR_*`).
  int sendConfirmed(ConfirmedRequestCommand command);

  /// Asks the network for the address of [deviceId] (targeted Who-Is).
  void requestBinding(int deviceId);
}

/// Called when the scheduler gives up on a request.
typedef RequestFailureCallback =
    void Function(ConfirmedRequestCommand command, BacnetException error);

final class _Request {
  _Request(this.command, this.deadline);

  final ConfirmedRequestCommand command;
  final int deadline;
}

final class _Device {
  _Device(this.id);

  final int id;
  final Queue<_Request> queue = Queue<_Request>();
  int inFlight = 0;
  bool scheduled = false;
  bool binding = false;
  int bindDeadline = 0;
  int nextBindRequest = 0;
}

/// Schedules confirmed requests on the 255 transaction slots of the stack.
///
/// - Requests are queued per device and released round-robin while fewer
///   than [maxInFlight] (all devices) and [maxInFlightPerDevice] requests
///   are outstanding.
/// - More than [maxQueued] waiting requests fail fast with
///   [BacnetQueueFullException].
/// - Requests to a device without address binding wait while the device is
///   resolved (a Who-Is every [bindRetryIntervalMs] until [bindTimeoutMs]).
/// - Every request has a deadline (`timeoutMs` of the command); outstanding
///   requests are additionally released after the deadline plus
///   [retryWindowMs] in case the stack never reported their end.
class RequestScheduler {
  /// Creates a scheduler.
  RequestScheduler({
    required RequestTransport transport,
    required RequestFailureCallback onFailure,
    required this.maxInFlight,
    required this.maxInFlightPerDevice,
    required this.maxQueued,
    required this.bindTimeoutMs,
    required this.retryWindowMs,
    this.bindRetryIntervalMs = 1000,
    int Function()? clock,
  }) : _transport = transport,
       _onFailure = onFailure,
       _clock = clock ?? _monotonicMillis();

  /// Maximum outstanding requests over all devices.
  final int maxInFlight;

  /// Maximum outstanding requests per device.
  final int maxInFlightPerDevice;

  /// Maximum waiting requests.
  final int maxQueued;

  /// Time to resolve the address of a device.
  final int bindTimeoutMs;

  /// Time between targeted Who-Is requests while resolving a device.
  final int bindRetryIntervalMs;

  /// Grace period after the deadline of an outstanding request.
  final int retryWindowMs;

  final RequestTransport _transport;
  final RequestFailureCallback _onFailure;
  final int Function() _clock;

  final Map<int, _Device> _devices = {};
  final Queue<_Device> _ready = Queue<_Device>();
  final Set<_Device> _binding = {};
  final List<_Request?> _inFlight = List<_Request?>.filled(256, null);
  int _inFlightCount = 0;
  int _queuedCount = 0;

  /// Requests waiting to be sent.
  int get queued => _queuedCount;

  /// Requests sent and not yet answered.
  int get inFlight => _inFlightCount;

  /// Devices whose address is being resolved.
  int get binding => _binding.length;

  /// Queues [command]; call [pump] to send.
  void enqueue(ConfirmedRequestCommand command) {
    if (_queuedCount >= maxQueued) {
      _onFailure(
        command,
        BacnetQueueFullException(
          'request queue full ($_queuedCount requests waiting)',
        ),
      );
      return;
    }
    final device = _devices.putIfAbsent(
      command.deviceId,
      () => _Device(command.deviceId),
    );
    device.queue.add(_Request(command, _clock() + command.timeoutMs));
    _queuedCount++;
    _schedule(device);
  }

  /// Sends queued requests while transaction slots are available.
  void pump() {
    while (_inFlightCount < maxInFlight && _ready.isNotEmpty) {
      final device = _ready.removeFirst()..scheduled = false;
      if (device.binding ||
          device.queue.isEmpty ||
          device.inFlight >= maxInFlightPerDevice) {
        continue;
      }
      final request = device.queue.removeFirst();
      _queuedCount--;
      final now = _clock();
      if (now >= request.deadline) {
        _onFailure(request.command, _expired(device));
        _schedule(device);
        continue;
      }
      final rc = _transport.sendConfirmed(request.command);
      if (rc > 0) {
        _track(rc, request, device);
        continue;
      }
      switch (rc) {
        case BP_ERR_NOT_BOUND:
          _requeue(device, request);
          _startBinding(device, now);
        case BP_ERR_NO_TRANSACTION:
          // every invoke id is busy (e.g. server COV notifications)
          _requeue(device, request);
          _schedule(device);
          return;
        default:
          _onFailure(request.command, nativeError(rc));
          _schedule(device);
      }
    }
  }

  /// Releases the slot of [invokeId] and returns its request, or null when
  /// the invoke id is not outstanding (late or foreign answer).
  ConfirmedRequestCommand? complete(int invokeId) {
    final request = _inFlight[invokeId];
    if (request == null) return null;
    _inFlight[invokeId] = null;
    _inFlightCount--;
    final device = _devices[request.command.deviceId];
    if (device != null) {
      device.inFlight--;
      _schedule(device);
    }
    return request.command;
  }

  /// The address of [deviceId] became known: resume its queue.
  void deviceBound(int deviceId) {
    final device = _devices[deviceId];
    if (device == null || !device.binding) return;
    device.binding = false;
    _binding.remove(device);
    _schedule(device);
  }

  /// Handles timers: binding retries and timeouts, expired requests.
  void sweep() {
    final now = _clock();
    // queues first: a device without waiting requests stops binding
    _sweepQueues(now);
    _sweepBindings(now);
    _sweepInFlight(now);
    // forget idle devices to bound memory
    if (_devices.length > 4096) {
      _devices.removeWhere(
        (_, d) => d.queue.isEmpty && d.inFlight == 0 && !d.binding,
      );
    }
  }

  /// Fails every queued and outstanding request with [error].
  void cancelAll(BacnetException error) {
    for (var i = 0; i < _inFlight.length; i++) {
      final request = _inFlight[i];
      if (request != null) {
        _inFlight[i] = null;
        _onFailure(request.command, error);
      }
    }
    for (final device in _devices.values) {
      for (final request in device.queue) {
        _onFailure(request.command, error);
      }
    }
    _inFlightCount = 0;
    _queuedCount = 0;
    _devices.clear();
    _ready.clear();
    _binding.clear();
  }

  void _track(int invokeId, _Request request, _Device device) {
    if (_inFlight[invokeId] != null) {
      // the stack recycled the invoke id without reporting the end of the
      // previous transaction: release it instead of leaking a slot
      final stale = complete(invokeId)!;
      _onFailure(stale, _noAnswer(stale.deviceId));
    }
    _inFlight[invokeId] = request;
    _inFlightCount++;
    device.inFlight++;
    _schedule(device);
  }

  void _requeue(_Device device, _Request request) {
    device.queue.addFirst(request);
    _queuedCount++;
  }

  void _schedule(_Device device) {
    if (!device.scheduled &&
        !device.binding &&
        device.queue.isNotEmpty &&
        device.inFlight < maxInFlightPerDevice) {
      device.scheduled = true;
      _ready.addLast(device);
    }
  }

  void _startBinding(_Device device, int now) {
    if (device.binding) return;
    device
      ..binding = true
      ..bindDeadline = now + bindTimeoutMs;
    _binding.add(device);
    _requestBinding(device, now);
  }

  void _requestBinding(_Device device, int now) {
    device.nextBindRequest = now + bindRetryIntervalMs;
    _transport.requestBinding(device.id);
  }

  void _sweepBindings(int now) {
    for (final device in _binding.toList()) {
      // stop when the deadline passed or nothing waits for the address
      if (now >= device.bindDeadline || device.queue.isEmpty) {
        device.binding = false;
        _binding.remove(device);
        final error = _notFound(device.id);
        for (final request in device.queue) {
          _onFailure(request.command, error);
        }
        _queuedCount -= device.queue.length;
        device.queue.clear();
      } else if (now >= device.nextBindRequest) {
        _requestBinding(device, now);
      }
    }
  }

  void _sweepInFlight(int now) {
    if (_inFlightCount == 0) return;
    for (var invokeId = 1; invokeId < _inFlight.length; invokeId++) {
      final request = _inFlight[invokeId];
      if (request != null && now >= request.deadline + retryWindowMs) {
        complete(invokeId);
        _onFailure(request.command, _noAnswer(request.command.deviceId));
      }
    }
  }

  void _sweepQueues(int now) {
    if (_queuedCount == 0) return;
    for (final device in _devices.values) {
      if (device.queue.isEmpty) continue;
      final before = device.queue.length;
      device.queue.removeWhere((request) {
        if (now < request.deadline) return false;
        _onFailure(request.command, _expired(device));
        return true;
      });
      _queuedCount -= before - device.queue.length;
    }
  }

  BacnetException _expired(_Device device) => device.binding
      ? _notFound(device.id)
      : const BacnetTimeoutException('request expired in the queue');

  static BacnetException _notFound(int deviceId) =>
      BacnetDeviceNotFoundException(
        'device $deviceId did not answer Who-Is',
        deviceId: deviceId,
      );

  static BacnetException _noAnswer(int deviceId) =>
      BacnetTimeoutException('device $deviceId did not answer');
}

int Function() _monotonicMillis() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsedMilliseconds;
}
