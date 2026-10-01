// The limits each test depends on are spelled out even when they match
// the defaults of the helper.
// ignore_for_file: avoid_redundant_argument_values
import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/native/bindings.g.dart';
import 'package:bacnet_plugin/src/native/protocol.dart';
import 'package:bacnet_plugin/src/native/scheduler.dart';
import 'package:test/test.dart';

/// Records the requests sent by the scheduler and answers them with
/// sequential invoke ids or scripted result codes.
final class FakeTransport implements RequestTransport {
  final List<ConfirmedRequestCommand> sent = [];
  final List<int> bindingRequests = [];

  /// Devices without address binding.
  final Set<int> unbound = {};

  /// Result codes returned instead of an invoke id (consumed in order).
  final List<int> scripted = [];

  int _nextInvokeId = 1;

  @override
  int sendConfirmed(ConfirmedRequestCommand command) {
    if (scripted.isNotEmpty) {
      final rc = scripted.removeAt(0);
      if (rc < 0) return rc;
    }
    if (unbound.contains(command.deviceId)) return BP_ERR_NOT_BOUND;
    sent.add(command);
    final invokeId = _nextInvokeId;
    _nextInvokeId = _nextInvokeId % 255 + 1;
    return invokeId;
  }

  /// Makes the next request reuse [invokeId].
  void reuseInvokeId(int invokeId) => _nextInvokeId = invokeId;

  @override
  void requestBinding(int deviceId) => bindingRequests.add(deviceId);
}

void main() {
  late FakeTransport transport;
  late Map<int, BacnetException> failures;
  late int now;
  var nextId = 0;

  RequestScheduler scheduler({
    int maxInFlight = 10,
    int maxInFlightPerDevice = 2,
    int maxQueued = 100,
    int bindTimeoutMs = 5000,
    int retryWindowMs = 1000,
    int offlineAfterTimeouts = 0,
    int offlineRetryMs = 30000,
  }) => RequestScheduler(
    transport: transport,
    onFailure: (command, error) => failures[command.id] = error,
    maxInFlight: maxInFlight,
    maxInFlightPerDevice: maxInFlightPerDevice,
    maxQueued: maxQueued,
    bindTimeoutMs: bindTimeoutMs,
    retryWindowMs: retryWindowMs,
    offlineAfterTimeouts: offlineAfterTimeouts,
    offlineRetryMs: offlineRetryMs,
    clock: () => now,
  );

  ConfirmedRequestCommand request(
    int deviceId, {
    int timeoutMs = 10000,
    bool background = false,
  }) => ConfirmedRequestCommand(
    nextId++,
    deviceId: deviceId,
    service: BacnetConfirmedService.readProperty,
    payload: Uint8List(0),
    timeoutMs: timeoutMs,
    background: background,
  );

  setUp(() {
    transport = FakeTransport();
    failures = {};
    now = 0;
  });

  group('RequestScheduler', () {
    test('sends queued requests when pumped', () {
      final s = scheduler();
      final a = request(1);
      final b = request(2);
      s
        ..enqueue(a)
        ..enqueue(b);
      expect(s.queued, 2);
      expect(transport.sent, isEmpty);

      s.pump();
      expect(transport.sent, [a, b]);
      expect(s.queued, 0);
      expect(s.inFlight, 2);
    });

    test('respects the global limit', () {
      final s = scheduler(maxInFlight: 3, maxInFlightPerDevice: 10);
      for (var device = 1; device <= 5; device++) {
        s.enqueue(request(device));
      }
      s.pump();
      expect(transport.sent, hasLength(3));
      expect(s.queued, 2);

      s
        ..complete(1)
        ..pump();
      expect(transport.sent, hasLength(4));
    });

    test('respects the per device limit and round-robins devices', () {
      final s = scheduler(maxInFlightPerDevice: 2);
      for (var i = 0; i < 4; i++) {
        s.enqueue(request(1));
      }
      s
        ..enqueue(request(2))
        ..pump();
      expect(transport.sent.map((c) => c.deviceId), [1, 2, 1]);
      expect(s.queued, 2);

      // completing a request of device 1 releases the next one
      expect(s.complete(1)?.deviceId, 1);
      s.pump();
      expect(transport.sent.map((c) => c.deviceId), [1, 2, 1, 1]);
    });

    test('fails fast when the queue is full', () {
      final s = scheduler(maxQueued: 2);
      final overflow = request(1);
      s
        ..enqueue(request(1))
        ..enqueue(request(1))
        ..enqueue(overflow);
      expect(s.queued, 2);
      expect(failures[overflow.id], isA<BacnetQueueFullException>());
    });

    test('complete returns null for unknown invoke ids', () {
      final s = scheduler();
      expect(s.complete(42), isNull);
      s
        ..enqueue(request(1))
        ..pump();
      expect(s.complete(1), isNotNull);
      expect(s.complete(1), isNull, reason: 'late duplicate answer');
      expect(s.inFlight, 0);
    });

    test('binds unknown devices before sending', () {
      final s = scheduler();
      transport.unbound.add(7);
      final r = request(7);
      s
        ..enqueue(r)
        ..pump();
      expect(transport.bindingRequests, [7]);
      expect(s.binding, 1);
      expect(s.queued, 1);
      expect(s.inFlight, 0);

      transport.unbound.remove(7);
      s
        ..deviceBound(7)
        ..pump();
      expect(s.binding, 0);
      expect(transport.sent, [r]);
    });

    test('repeats Who-Is and fails the queue when binding times out', () {
      final s = scheduler(bindTimeoutMs: 2500);
      transport.unbound.add(7);
      final a = request(7);
      final b = request(7);
      s
        ..enqueue(a)
        ..enqueue(b)
        ..pump();
      expect(transport.bindingRequests, [7]);

      now = 1000;
      s.sweep();
      now = 2000;
      s.sweep();
      expect(transport.bindingRequests, [7, 7, 7]);
      expect(failures, isEmpty);

      now = 2500;
      s.sweep();
      expect(failures.keys, unorderedEquals([a.id, b.id]));
      expect(
        failures[a.id],
        isA<BacnetDeviceNotFoundException>().having(
          (e) => e.deviceId,
          'deviceId',
          7,
        ),
      );
      expect(s.queued, 0);
      expect(s.binding, 0);
    });

    test('stops binding when no request waits for the device', () {
      final s = scheduler(bindTimeoutMs: 5000);
      transport.unbound.add(7);
      final r = request(7, timeoutMs: 1500);
      s
        ..enqueue(r)
        ..pump();
      now = 1000;
      s.sweep();
      expect(transport.bindingRequests, [7, 7]);

      now = 1500;
      s.sweep();
      expect(failures[r.id], isA<BacnetDeviceNotFoundException>());
      expect(s.binding, 0);
      now = 2500;
      s.sweep();
      expect(transport.bindingRequests, [7, 7], reason: 'no further Who-Is');
    });

    test('expires requests waiting in the queue', () {
      final s = scheduler(maxInFlight: 1);
      final first = request(1);
      final waiting = request(2, timeoutMs: 500);
      s
        ..enqueue(first)
        ..enqueue(waiting)
        ..pump();
      now = 600;
      s.sweep();
      expect(failures[waiting.id], isA<BacnetTimeoutException>());
      expect(failures.containsKey(first.id), isFalse);
      expect(s.queued, 0);
    });

    test('expires requests dequeued after their deadline', () {
      final s = scheduler();
      final r = request(1, timeoutMs: 100);
      s.enqueue(r);
      now = 100;
      s.pump();
      expect(failures[r.id], isA<BacnetTimeoutException>());
      expect(transport.sent, isEmpty);
    });

    test('releases outstanding requests after deadline and retry window', () {
      final s = scheduler(retryWindowMs: 1000);
      final r = request(1, timeoutMs: 500);
      s
        ..enqueue(r)
        ..pump();
      now = 1499;
      s.sweep();
      expect(s.inFlight, 1);
      now = 1500;
      s.sweep();
      expect(s.inFlight, 0);
      expect(failures[r.id], isA<BacnetTimeoutException>());
    });

    test('fails a stale request when its invoke id is recycled', () {
      final s = scheduler(maxInFlightPerDevice: 10);
      final stale = request(1);
      final fresh = request(1);
      s
        ..enqueue(stale)
        ..pump();
      transport.reuseInvokeId(1);
      s
        ..enqueue(fresh)
        ..pump();
      expect(failures[stale.id], isA<BacnetTimeoutException>());
      expect(s.inFlight, 1);
      expect(s.complete(1), same(fresh));
    });

    test('retries later when no transaction is free', () {
      final s = scheduler();
      final r = request(1);
      transport.scripted.add(BP_ERR_NO_TRANSACTION);
      s
        ..enqueue(r)
        ..pump();
      expect(transport.sent, isEmpty);
      expect(s.queued, 1);
      s.pump();
      expect(transport.sent, [r]);
    });

    test('maps other native errors to exceptions', () {
      final s = scheduler();
      final r = request(1);
      transport.scripted.add(BP_ERR_SEND_FAILED);
      s
        ..enqueue(r)
        ..pump();
      expect(failures[r.id], isA<BacnetException>());
      expect(s.queued, 0);
      expect(s.inFlight, 0);
    });

    test('cancelAll fails queued and outstanding requests', () {
      final s = scheduler(maxInFlight: 1);
      final sent = request(1);
      final queued = request(2);
      s
        ..enqueue(sent)
        ..enqueue(queued)
        ..pump()
        ..cancelAll(const BacnetException('stopped'));
      expect(failures.keys, unorderedEquals([sent.id, queued.id]));
      expect(s.queued, 0);
      expect(s.inFlight, 0);
    });

    group('background requests', () {
      test('wait behind normal requests', () {
        final s = scheduler(maxInFlight: 1, maxInFlightPerDevice: 10);
        final bulk = [for (var i = 0; i < 3; i++) request(1, background: true)];
        bulk.forEach(s.enqueue);
        final interactive = request(2);
        s
          ..enqueue(interactive)
          ..pump();
        expect(transport.sent, [interactive]);
      });

      test('leave slots for normal requests', () {
        final s = scheduler(maxInFlight: 8, maxInFlightPerDevice: 4);
        for (var i = 0; i < 20; i++) {
          s.enqueue(request(i % 5 + 1, background: true));
        }
        s.pump();
        expect(s.inFlight, 6, reason: '3/4 of the global slots');

        final t = scheduler(maxInFlight: 100, maxInFlightPerDevice: 4);
        for (var i = 0; i < 10; i++) {
          t.enqueue(request(1, background: true));
        }
        t.pump();
        expect(t.inFlight, 3, reason: 'one slot per device kept free');
        t
          ..enqueue(request(1))
          ..pump();
        expect(t.inFlight, 4);
      });
    });

    group('offline devices', () {
      test('fail fast after consecutive timeouts', () {
        final s = scheduler(offlineAfterTimeouts: 2, maxInFlightPerDevice: 1);
        final first = request(1);
        final second = request(1);
        final waiting = request(1);
        s
          ..enqueue(first)
          ..enqueue(second)
          ..enqueue(waiting)
          ..pump();
        s.complete(1, answered: false);
        s.pump();
        expect(failures, isEmpty, reason: 'one timeout is not enough');
        s.complete(2, answered: false);
        expect(
          failures[waiting.id],
          isA<BacnetDeviceOfflineException>()
              .having((e) => e.deviceId, 'deviceId', 1)
              .having((e) => e.retryAfter, 'retryAfter', isNot(Duration.zero)),
        );
        expect(s.offline, 1);

        final late = request(1);
        s.enqueue(late);
        expect(failures[late.id], isA<BacnetDeviceOfflineException>());
        expect(failures[late.id], isA<BacnetTimeoutException>());
      });

      test('are probed with one request after the retry interval', () {
        final s = scheduler(
          offlineAfterTimeouts: 1,
          offlineRetryMs: 1000,
          maxInFlightPerDevice: 4,
        );
        s
          ..enqueue(request(1))
          ..pump()
          ..complete(1, answered: false);
        expect(s.offline, 1);

        now = 1000;
        s
          ..enqueue(request(1))
          ..enqueue(request(1))
          ..pump();
        expect(s.inFlight, 1, reason: 'a single probe');

        // the probe fails: offline for twice as long
        s.complete(2, answered: false);
        now = 2999;
        final early = request(1);
        s.enqueue(early);
        expect(failures[early.id], isA<BacnetDeviceOfflineException>());

        now = 3000;
        s
          ..enqueue(request(1))
          ..enqueue(request(1))
          ..pump();
        expect(s.inFlight, 1);
        // the probe succeeds: back to normal
        s
          ..complete(3)
          ..pump();
        expect(s.offline, 0);
        expect(s.inFlight, 1);
        s
          ..enqueue(request(1))
          ..enqueue(request(1))
          ..pump();
        expect(s.inFlight, 3);
      });

      test('come back with an I-Am', () {
        final s = scheduler(offlineAfterTimeouts: 1);
        s
          ..enqueue(request(1))
          ..pump()
          ..complete(1, answered: false)
          ..deviceBound(1);
        expect(s.offline, 0);
        final next = request(1);
        s
          ..enqueue(next)
          ..pump();
        expect(transport.sent.last, next);
      });

      test('answers reset the timeout count', () {
        final s = scheduler(offlineAfterTimeouts: 2);
        for (var i = 0; i < 4; i++) {
          s
            ..enqueue(request(1))
            ..pump();
        }
        s
          ..complete(1, answered: false)
          ..pump()
          ..complete(2)
          ..pump();
        expect(s.inFlight, 2);
        s.complete(3, answered: false);
        expect(s.offline, 0, reason: 'the answer in between reset the count');
        s.complete(4, answered: false);
        expect(s.offline, 1);
      });
    });

    test('cancel drops queued requests silently', () {
      final s = scheduler(maxInFlight: 1);
      final sent = request(1);
      final dropped = request(2);
      final kept = request(3);
      s
        ..enqueue(sent)
        ..enqueue(dropped)
        ..enqueue(kept)
        ..pump()
        ..cancel(dropped.id);
      expect(s.queued, 1);
      s
        ..complete(1)
        ..pump();
      expect(transport.sent, [sent, kept]);
      expect(failures, isEmpty);
    });
  });
}
