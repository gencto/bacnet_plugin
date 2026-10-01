import 'dart:async';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockBacnetClient extends Mock implements BacnetClient {}

void main() {
  const deviceId = 1234;
  const object = BacnetObject(type: 0, instance: 1);
  const propertyId = BacnetPropertyId.presentValue;

  late MockBacnetClient client;
  late StreamController<CovNotificationEvent> covController;

  void stubSubscribe({Object? error}) {
    when(
      () => client.subscribeCOV(
        any(),
        any(),
        any(),
        propId: any(named: 'propId'),
        processId: any(named: 'processId'),
        lifetime: any(named: 'lifetime'),
        confirmed: any(named: 'confirmed'),
      ),
    ).thenAnswer((_) async {
      if (error != null) throw error;
    });
  }

  setUpAll(() {
    registerFallbackValue(Duration.zero);
    registerFallbackValue(BacnetLogLevel.info);
  });

  setUp(() {
    client = MockBacnetClient();
    covController = StreamController<CovNotificationEvent>.broadcast();
    when(() => client.covEvents).thenAnswer((_) => covController.stream);
    when(() => client.allocateProcessId()).thenReturn(42);
    when(
      () => client.readProperty(deviceId, 0, 1, propertyId),
    ).thenAnswer((_) async => 100.0);
    when(
      () => client.unsubscribeCOV(
        any(),
        any(),
        any(),
        propId: any(named: 'propId'),
        processId: any(named: 'processId'),
      ),
    ).thenAnswer((_) async {});
    when(() => client.log(any(), any(), any(), any())).thenReturn(null);
  });

  tearDown(() => covController.close());

  group('PropertyMonitor', () {
    test('emits the current value first', () async {
      stubSubscribe();
      final monitor = PropertyMonitor(client);

      final update = await monitor
          .monitor(deviceId: deviceId, object: object, propertyId: propertyId)
          .first;

      expect(update.value, 100.0);
      expect(update.source, UpdateSource.manual);
    });

    test('emits COV values without additional reads', () async {
      stubSubscribe();
      final monitor = PropertyMonitor(client);
      final stream = monitor.monitor(
        deviceId: deviceId,
        object: object,
        propertyId: propertyId,
      );

      final updates = <PropertyUpdate>[];
      final subscription = stream.listen(updates.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      covController
        // other subscription: ignored
        ..add(
          const CovNotificationEvent(
            deviceId: deviceId,
            objectType: 0,
            instance: 1,
            timestamp: 'now',
            subscriberProcessId: 7,
            values: {propertyId: 1.0},
          ),
        )
        ..add(
          const CovNotificationEvent(
            deviceId: deviceId,
            objectType: 0,
            instance: 1,
            timestamp: 'now',
            subscriberProcessId: 42,
            values: {propertyId: 150.0},
          ),
        );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await subscription.cancel();

      expect(updates.map((u) => u.value), [100.0, 150.0]);
      expect(updates.last.source, UpdateSource.cov);
      verify(() => client.readProperty(deviceId, 0, 1, propertyId)).called(1);
      verify(
        () => client.subscribeCOV(
          deviceId,
          0,
          1,
          propId: propertyId,
          processId: 42,
          lifetime: any(named: 'lifetime'),
          confirmed: false,
        ),
      ).called(1);
      verify(
        () => client.unsubscribeCOV(
          deviceId,
          0,
          1,
          propId: propertyId,
          processId: 42,
        ),
      ).called(1);
    });

    test('polls when polling is preferred', () async {
      final monitor = PropertyMonitor(client);

      final list = await monitor
          .monitor(
            deviceId: deviceId,
            object: object,
            propertyId: propertyId,
            preferPolling: true,
            pollingInterval: const Duration(milliseconds: 10),
          )
          .take(3)
          .toList();

      expect(list, hasLength(3));
      expect(list.every((u) => u.source == UpdateSource.manual), isTrue);
      verifyNever(
        () => client.subscribeCOV(
          any(),
          any(),
          any(),
          propId: any(named: 'propId'),
          processId: any(named: 'processId'),
          lifetime: any(named: 'lifetime'),
          confirmed: any(named: 'confirmed'),
        ),
      );
    });

    test('falls back to polling when the subscription fails', () async {
      stubSubscribe(
        error: const BacnetProtocolException(
          'not supported',
          errorClass: BacnetErrorClass.services,
          errorCode: BacnetErrorCode.covSubscriptionFailed,
        ),
      );
      final monitor = PropertyMonitor(client);

      final list = await monitor
          .monitor(
            deviceId: deviceId,
            object: object,
            propertyId: propertyId,
            pollingInterval: const Duration(milliseconds: 10),
          )
          .take(2)
          .toList();

      expect(list.last.source, UpdateSource.missingCovFallback);
      verifyNever(
        () => client.unsubscribeCOV(
          any(),
          any(),
          any(),
          propId: any(named: 'propId'),
          processId: any(named: 'processId'),
        ),
      );
    });

    test('renews the subscription before it expires', () async {
      stubSubscribe();
      final monitor = PropertyMonitor(
        client,
        subscriptionLifetime: const Duration(milliseconds: 40),
      );
      final subscription = monitor
          .monitor(deviceId: deviceId, object: object, propertyId: propertyId)
          .listen((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 150));
      await subscription.cancel();

      final calls = verify(
        () => client.subscribeCOV(
          any(),
          any(),
          any(),
          propId: any(named: 'propId'),
          processId: any(named: 'processId'),
          lifetime: any(named: 'lifetime'),
          confirmed: any(named: 'confirmed'),
        ),
      ).callCount;
      expect(calls, greaterThanOrEqualTo(3));
      expect(monitor.activeCount, 0);
    });

    test('shares one stream per property', () {
      stubSubscribe();
      final monitor = PropertyMonitor(client);
      final a = monitor.monitor(
        deviceId: deviceId,
        object: object,
        propertyId: propertyId,
      );
      final b = monitor.monitor(
        deviceId: deviceId,
        object: object,
        propertyId: propertyId,
      );
      expect(a, equals(b));
      expect(monitor.activeCount, 1);
    });
  });
}
