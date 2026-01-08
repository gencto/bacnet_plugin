import 'dart:async';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockBacnetClient extends Mock implements BacnetClient {}

void main() {
  late MockBacnetClient mockClient;
  late DeviceScanner scanner;
  late StreamController<WorkerResponse> eventController;

  setUp(() {
    mockClient = MockBacnetClient();
    eventController = StreamController<WorkerResponse>.broadcast();
    when(() => mockClient.events).thenAnswer((_) => eventController.stream);
    scanner = DeviceScanner(mockClient);
  });

  tearDown(() {
    eventController.close();
  });

  group('DeviceScanner', () {
    group('discoverDevices', () {
      test('discovers devices from I-Am responses', () async {
        // Arrange
        when(
          () => mockClient.sendWhoIs(
            lowLimit: any(named: 'lowLimit'),
            highLimit: any(named: 'highLimit'),
          ),
        ).thenAnswer((_) async {});

        // Mock getDeviceDetails behavior via readMultiple for device 1234
        when(() => mockClient.readMultiple(1234, any())).thenAnswer(
          (_) async => {
            '${BacnetObjectType.device}:1234': {
              BacnetPropertyId.objectName: 'Test Device',
              BacnetPropertyId.vendorIdentifier: 99,
              BacnetPropertyId.vendorName: 'Test Vendor',
              BacnetPropertyId.modelName: 'Test Model',
            },
          },
        );

        // Act
        final future = scanner.discoverDevices(
          timeout: const Duration(milliseconds: 100),
        );

        // Emit I-Am response
        eventController.add(
          const IAmResponse(deviceId: 1234, len: 0, mac: [], net: 0),
        );

        final devices = await future;

        // Assert
        expect(devices, hasLength(1));
        expect(devices.first.deviceId, 1234);
        expect(devices.first.deviceName, 'Test Device');
        verify(() => mockClient.sendWhoIs()).called(1);
      });

      test('sorts discovered devices by ID', () async {
        // Arrange
        when(
          () => mockClient.sendWhoIs(
            lowLimit: any(named: 'lowLimit'),
            highLimit: any(named: 'highLimit'),
          ),
        ).thenAnswer((_) async {});

        // Mock responses for devices 10 and 20
        when(() => mockClient.readMultiple(10, any())).thenAnswer(
          (_) async => {
            '${BacnetObjectType.device}:10': {
              BacnetPropertyId.objectName: 'Device 10',
            },
          },
        );
        when(() => mockClient.readMultiple(20, any())).thenAnswer(
          (_) async => {
            '${BacnetObjectType.device}:20': {
              BacnetPropertyId.objectName: 'Device 20',
            },
          },
        );

        // Act
        final future = scanner.discoverDevices(
          timeout: const Duration(milliseconds: 100),
        );

        // Emit out of order
        eventController.add(
          const IAmResponse(deviceId: 20, len: 0, mac: [], net: 0),
        );
        eventController.add(
          const IAmResponse(deviceId: 10, len: 0, mac: [], net: 0),
        );

        final devices = await future;

        // Assert
        expect(devices, hasLength(2));
        expect(devices[0].deviceId, 10);
        expect(devices[1].deviceId, 20);
      });

      test('ignores duplicate I-Am responses', () async {
        // Arrange
        when(
          () => mockClient.sendWhoIs(
            lowLimit: any(named: 'lowLimit'),
            highLimit: any(named: 'highLimit'),
          ),
        ).thenAnswer((_) async {});

        when(() => mockClient.readMultiple(10, any())).thenAnswer(
          (_) async => {
            '${BacnetObjectType.device}:10': {
              BacnetPropertyId.objectName: 'Device 10',
            },
          },
        );

        // Act
        final future = scanner.discoverDevices(
          timeout: const Duration(milliseconds: 100),
        );

        eventController.add(
          const IAmResponse(deviceId: 10, len: 0, mac: [], net: 0),
        );
        eventController.add(
          const IAmResponse(deviceId: 10, len: 0, mac: [], net: 0),
        );

        final devices = await future;

        // Assert
        expect(devices, hasLength(1));
        verify(() => mockClient.readMultiple(10, any())).called(1);
      });
    });

    group('scanDevice', () {
      test('scans objects and reads properties', () async {
        // Arrange
        const deviceId = 1234;
        const obj1 = BacnetObject(type: 0, instance: 1);
        const obj2 = BacnetObject(type: 1, instance: 2);

        when(
          () => mockClient.scanDevice(deviceId),
        ).thenAnswer((_) async => [obj1, obj2]);

        when(() => mockClient.readMultiple(deviceId, any())).thenAnswer((
          invocation,
        ) async {
          // Verify batching logic via invocation arguments if needed
          // Return mock results
          return {
            '0:1': {85: 100.0},
            '1:2': {85: 200.0},
          };
        });

        // Act
        final results = await scanner.scanDevice(deviceId, propertyIds: [85]);

        // Assert
        expect(results, hasLength(2));
        expect(results[obj1]?[85], 100.0);
        expect(results[obj2]?[85], 200.0);
      });
    });

    group('getDeviceDetails', () {
      test('throws Exception on connection failure', () async {
        // Arrange
        when(
          () => mockClient.readMultiple(any(), any()),
        ).thenThrow(Exception('Connection failed'));

        // Act & Assert
        expect(() => scanner.getDeviceDetails(1234), throwsException);
      });
    });
  });
}
