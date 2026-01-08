import 'dart:async';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockBacnetClient extends Mock implements BacnetClient {}

void main() {
  late MockBacnetClient mockClient;
  late StreamController<dynamic> eventController;
  late PropertyMonitor monitor;

  setUp(() {
    mockClient = MockBacnetClient();
    eventController = StreamController<dynamic>.broadcast();
    when(() => mockClient.events).thenAnswer((_) => eventController.stream);
    monitor = PropertyMonitor(mockClient);
  });

  tearDown(() {
    eventController.close();
  });

  group('PropertyMonitor', () {
    test('monitor emits initial value immediately', () async {
      // Arrange
      const deviceId = 1234;
      const object = BacnetObject(type: 0, instance: 1);
      const propertyId = 85;
      const initialValue = 100.0;

      when(
        () => mockClient.readProperty(deviceId, 0, 1, 85),
      ).thenAnswer((_) async => initialValue);

      when(
        () => mockClient.subscribeCOV(
          any(),
          any(),
          any(),
          propId: any(named: 'propId'),
        ),
      ).thenAnswer((_) async {});

      // Act
      final stream = monitor.monitor(
        deviceId: deviceId,
        object: object,
        propertyId: propertyId,
      );

      // Assert
      final update = await stream.first;
      expect(update.value, initialValue);
      expect(update.source, UpdateSource.manual);
    });

    test('monitor falls back to polling if preferPolling is true', () async {
      // Arrange
      const deviceId = 1234;
      const object = BacnetObject(type: 0, instance: 1);
      const propertyId = 85;
      const polledValue = 200.0;

      when(
        () => mockClient.readProperty(deviceId, 0, 1, 85),
      ).thenAnswer((_) async => polledValue);

      // Act
      final stream = monitor.monitor(
        deviceId: deviceId,
        object: object,
        propertyId: propertyId,
        preferPolling: true,
        pollingInterval: const Duration(milliseconds: 10),
      );

      // Assert
      // Wait for at least one polled value (skipping initial)
      final updates = stream.take(2);
      final list = await updates.toList();

      // First is initial manual read
      expect(list[0].value, polledValue);

      // Second is from polling loop
      expect(list[1].value, polledValue);
      expect(list[1].source, UpdateSource.manual);

      // Verify subscribeCOV was NOT called
      verifyNever(
        () => mockClient.subscribeCOV(
          any(),
          any(),
          any(),
          propId: any(named: 'propId'),
        ),
      );
    });

    test('monitor triggers read on COV notification', () async {
      // Arrange
      const deviceId = 1234;
      const object = BacnetObject(type: 0, instance: 1);
      const propertyId = 85;
      const initialValue = 100.0;
      const newValue = 150.0;

      // Setup readProperty to return initial then new value
      var callCount = 0;
      when(() => mockClient.readProperty(deviceId, 0, 1, 85)).thenAnswer((
        _,
      ) async {
        callCount++;
        return callCount == 1 ? initialValue : newValue;
      });

      when(
        () => mockClient.subscribeCOV(
          any(),
          any(),
          any(),
          propId: any(named: 'propId'),
        ),
      ).thenAnswer((_) async {});

      // Act
      final stream = monitor.monitor(
        deviceId: deviceId,
        object: object,
        propertyId: propertyId,
      );

      // 1. Initial value
      // 2. Emit COV notification
      // 3. Should trigger read and emit new value

      expect(
        stream,
        emitsInOrder([
          predicate<PropertyUpdate>(
            (update) =>
                update.value == initialValue &&
                update.source == UpdateSource.manual,
          ),
          predicate<PropertyUpdate>(
            (update) =>
                update.value == newValue && update.source == UpdateSource.cov,
          ),
        ]),
      );

      // Trigger COV after a short delay to allow stream to start listening
      Future.delayed(const Duration(milliseconds: 50), () {
        eventController.add(
          const COVNotificationResponse(
            deviceId: deviceId,
            objectType: 0,
            instance: 1,
            timestamp: 'now',
          ),
        );
      });
    });
  });
}
