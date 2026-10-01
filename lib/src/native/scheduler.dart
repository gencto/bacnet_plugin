import 'dart:collection';
import 'dart:math' as math;

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
  bool cancelled = false;

  bool get background => command.background;
}

final class _Device {
  _Device(this.id);

  final int id;
  final Queue<_Request> normal = Queue<_Request>();
  final Queue<_Request> background = Queue<_Request>();
  int inFlight = 0;
  int backgroundInFlight = 0;
  bool readyNormal = false;
  bool readyBackground = false;

  // address resolution
  bool binding = false;
  int bindDeadline = 0;
  int nextBindRequest = 0;

  // health: consecutive timeouts, offline until (0: online), probing after
  // an offline period (one request at a time)
  int timeouts = 0;
  int offlineUntil = 0;
  int offlineBackoff = 0;
  bool probing = false;

  Queue<_Request> queueOf(_Request request) =>
      request.background ? background : normal;

  bool get idle =>
      normal.isEmpty &&
      background.isEmpty &&
      inFlight == 0 &&
      !binding &&
      timeouts == 0 &&
      offlineUntil == 0 &&
      !probing;
}

/// Schedules confirmed requests on the 255 transaction slots of the stack.
///
/// - Requests are queued per device and released round-robin while fewer
///   than [maxInFlight] (all devices) and [maxInFlightPerDevice] requests
///   are outstanding.
/// - Background requests wait behind normal ones and use at most three
///   quarters of [maxInFlight] and one slot less than
///   [maxInFlightPerDevice], so interactive requests are never stuck
///   behind bulk work.
/// - More than [maxQueued] waiting requests fail fast with
///   [BacnetQueueFullException].
/// - Requests to a device without address binding wait while the device is
///   resolved (a Who-Is every [bindRetryIntervalMs] until [bindTimeoutMs]).
/// - Every request has a deadline (`timeoutMs` of the command); outstanding
///   requests are additionally released after the deadline plus
///   [retryWindowMs] in case the stack never reported their end.
/// - After [offlineAfterTimeouts] consecutive timeouts (0 disables it) a
///   device is offline: its requests fail with
///   [BacnetDeviceOfflineException] for [offlineRetryMs] (doubling up to
///   8 times while it stays silent), then a single request probes it.
///   Any answer or an I-Am brings it back.
/// - [cancel] drops a queued request without reporting it.
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
    this.offlineAfterTimeouts = 0,
    this.offlineRetryMs = 30000,
    int Function()? clock,
  }) : _transport = transport,
       _onFailure = onFailure,
       _clock = clock ?? _monotonicMillis(),
       maxBackgroundInFlight = math.max(1, maxInFlight * 3 ~/ 4),
       maxBackgroundPerDevice = math.max(1, maxInFlightPerDevice - 1);

  /// Maximum outstanding requests over all devices.
  final int maxInFlight;

  /// Maximum outstanding requests per device.
  final int maxInFlightPerDevice;

  /// Maximum outstanding background requests over all devices.
  final int maxBackgroundInFlight;

  /// Maximum outstanding background requests per device.
  final int maxBackgroundPerDevice;

  /// Maximum waiting requests.
  final int maxQueued;

  /// Time to resolve the address of a device.
  final int bindTimeoutMs;

  /// Time between targeted Who-Is requests while resolving a device.
  final int bindRetryIntervalMs;

  /// Grace period after the deadline of an outstanding request.
  final int retryWindowMs;

  /// Consecutive timeouts after which a device is offline (0: never).
  final int offlineAfterTimeouts;

  /// Initial time a device stays offline.
  final int offlineRetryMs;

  final RequestTransport _transport;
  final RequestFailureCallback _onFailure;
  final int Function() _clock;

  final Map<int, _Device> _devices = {};
  final Queue<_Device> _readyNormal = Queue<_Device>();
  final Queue<_Device> _readyBackground = Queue<_Device>();
  final Set<_Device> _binding = {};
  final List<_Request?> _inFlight = List<_Request?>.filled(256, null);
  final Map<int, _Request> _queuedById = {};
  int _inFlightCount = 0;
  int _backgroundInFlight = 0;

  /// Requests waiting to be sent.
  int get queued => _queuedById.length;

  /// Requests sent and not yet answered.
  int get inFlight => _inFlightCount;

  /// Devices whose address is being resolved.
  int get binding => _binding.length;

  /// Devices currently considered offline.
  int get offline {
    final now = _clock();
    return _devices.values.where((d) => d.offlineUntil > now).length;
  }

  /// Queues [command]; call [pump] to send.
  void enqueue(ConfirmedRequestCommand command) {
    if (_queuedById.length >= maxQueued) {
      _onFailure(
        command,
        BacnetQueueFullException(
          'request queue full (${_queuedById.length} requests waiting)',
        ),
      );
      return;
    }
    final device = _devices.putIfAbsent(
      command.deviceId,
      () => _Device(command.deviceId),
    );
    final now = _clock();
    if (device.offlineUntil != 0) {
      if (now < device.offlineUntil) {
        _onFailure(command, _offline(device, now));
        return;
      }
      // offline period over: probe with one request at a time
      device
        ..offlineUntil = 0
        ..probing = true;
    }
    final request = _Request(command, now + command.timeoutMs);
    device.queueOf(request).add(request);
    _queuedById[command.id] = request;
    _schedule(device);
  }

  /// Drops the queued request [commandId] (an outstanding request keeps
  /// its transaction; its answer is ignored by the caller).
  void cancel(int commandId) {
    _queuedById.remove(commandId)?.cancelled = true;
  }

  /// Sends queued requests while transaction slots are available.
  void pump() {
    while (_inFlightCount < maxInFlight) {
      final _Device device;
      final bool background;
      if (_readyNormal.isNotEmpty) {
        device = _readyNormal.removeFirst()..readyNormal = false;
        background = false;
      } else if (_readyBackground.isNotEmpty &&
          _backgroundInFlight < maxBackgroundInFlight) {
        device = _readyBackground.removeFirst()..readyBackground = false;
        background = true;
      } else {
        return;
      }
      final queue = background ? device.background : device.normal;
      _dropCancelled(queue);
      if (device.binding ||
          queue.isEmpty ||
          device.inFlight >= _limit(device) ||
          (background && device.backgroundInFlight >= maxBackgroundPerDevice)) {
        continue;
      }
      final request = queue.removeFirst();
      _queuedById.remove(request.command.id);
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
  ///
  /// [answered] is false when the transaction timed out.
  ConfirmedRequestCommand? complete(int invokeId, {bool answered = true}) {
    final request = _release(invokeId);
    if (request == null) return null;
    final device = _devices[request.command.deviceId];
    if (device != null) {
      if (answered) {
        _deviceAnswered(device);
      } else {
        _deviceTimedOut(device, _clock());
      }
      _schedule(device);
    }
    return request.command;
  }

  /// The device announced itself (I-Am) or got a static binding: resume
  /// its queue and forget earlier timeouts.
  void deviceBound(int deviceId) {
    final device = _devices[deviceId];
    if (device == null) return;
    _deviceAnswered(device);
    if (device.binding) {
      device.binding = false;
      _binding.remove(device);
    }
    _schedule(device);
  }

  /// Handles timers: queue expiry, binding retries and timeouts, stale
  /// transactions.
  void sweep() {
    final now = _clock();
    // queues first: a device without waiting requests stops binding
    _sweepQueues(now);
    _sweepBindings(now);
    _sweepInFlight(now);
    // forget idle devices to bound memory
    if (_devices.length > 4096) {
      _devices.removeWhere((_, d) => d.idle);
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
    for (final request in _queuedById.values) {
      _onFailure(request.command, error);
    }
    _queuedById.clear();
    _inFlightCount = 0;
    _backgroundInFlight = 0;
    _devices.clear();
    _readyNormal.clear();
    _readyBackground.clear();
    _binding.clear();
  }

  int _limit(_Device device) => device.probing ? 1 : maxInFlightPerDevice;

  void _track(int invokeId, _Request request, _Device device) {
    if (_inFlight[invokeId] != null) {
      // the stack recycled the invoke id without reporting the end of the
      // previous transaction: release it instead of leaking a slot
      final stale = complete(invokeId, answered: false)!;
      _onFailure(stale, _noAnswer(stale.deviceId));
    }
    _inFlight[invokeId] = request;
    _inFlightCount++;
    device.inFlight++;
    if (request.background) {
      _backgroundInFlight++;
      device.backgroundInFlight++;
    }
    _schedule(device);
  }

  _Request? _release(int invokeId) {
    final request = _inFlight[invokeId];
    if (request == null) return null;
    _inFlight[invokeId] = null;
    _inFlightCount--;
    final device = _devices[request.command.deviceId];
    if (request.background) _backgroundInFlight--;
    if (device != null) {
      device.inFlight--;
      if (request.background) device.backgroundInFlight--;
    }
    return request;
  }

  void _requeue(_Device device, _Request request) {
    device.queueOf(request).addFirst(request);
    _queuedById[request.command.id] = request;
  }

  void _schedule(_Device device) {
    if (device.binding || device.inFlight >= _limit(device)) return;
    if (!device.readyNormal && device.normal.isNotEmpty) {
      device.readyNormal = true;
      _readyNormal.addLast(device);
    }
    if (!device.readyBackground &&
        device.background.isNotEmpty &&
        device.backgroundInFlight < maxBackgroundPerDevice) {
      device.readyBackground = true;
      _readyBackground.addLast(device);
    }
  }

  static void _dropCancelled(Queue<_Request> queue) {
    while (queue.isNotEmpty && queue.first.cancelled) {
      queue.removeFirst();
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

  void _deviceAnswered(_Device device) {
    device
      ..timeouts = 0
      ..offlineUntil = 0
      ..offlineBackoff = 0
      ..probing = false;
  }

  void _deviceTimedOut(_Device device, int now) {
    device.timeouts++;
    if (device.offlineUntil != 0) return;
    if (device.probing ||
        (offlineAfterTimeouts > 0 && device.timeouts >= offlineAfterTimeouts)) {
      _goOffline(device, now);
    }
  }

  void _goOffline(_Device device, int now) {
    device
      ..probing = false
      ..offlineBackoff = device.offlineBackoff == 0
          ? offlineRetryMs
          : math.min(device.offlineBackoff * 2, offlineRetryMs * 8)
      ..offlineUntil = now + device.offlineBackoff;
    final error = _offline(device, now);
    _failQueued(device, error);
  }

  void _failQueued(_Device device, BacnetException error) {
    for (final queue in [device.normal, device.background]) {
      for (final request in queue) {
        if (request.cancelled) continue;
        _queuedById.remove(request.command.id);
        _onFailure(request.command, error);
      }
      queue.clear();
    }
  }

  void _sweepBindings(int now) {
    for (final device in _binding.toList()) {
      final waiting =
          device.normal.any((r) => !r.cancelled) ||
          device.background.any((r) => !r.cancelled);
      // stop when the deadline passed or nothing waits for the address
      if (now >= device.bindDeadline || !waiting) {
        device.binding = false;
        _binding.remove(device);
        if (waiting) _failQueued(device, _notFound(device.id));
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
        complete(invokeId, answered: false);
        _onFailure(request.command, _noAnswer(request.command.deviceId));
      }
    }
  }

  void _sweepQueues(int now) {
    if (_queuedById.isEmpty) return;
    for (final device in _devices.values) {
      for (final queue in [device.normal, device.background]) {
        if (queue.isEmpty) continue;
        queue.removeWhere((request) {
          if (request.cancelled) return true;
          if (now < request.deadline) return false;
          _queuedById.remove(request.command.id);
          _onFailure(request.command, _expired(device));
          return true;
        });
      }
    }
  }

  BacnetException _expired(_Device device) => device.binding
      ? _notFound(device.id)
      : const BacnetTimeoutException('request expired in the queue');

  static BacnetException _offline(_Device device, int now) {
    final retryAfter = Duration(milliseconds: device.offlineUntil - now);
    return BacnetDeviceOfflineException(
      'device ${device.id} is offline after ${device.timeouts} timeouts, '
      'next attempt in ${retryAfter.inSeconds} s',
      deviceId: device.id,
      retryAfter: retryAfter,
    );
  }

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
