import 'dart:async';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockBacnetClient extends Mock implements BacnetClient {}

BacnetObject device(int instance) =>
    BacnetObject(type: BacnetObjectType.device, instance: instance);

void main() {
  late MockBacnetClient mockClient;
  late DeviceScanner scanner;
  late StreamController<BacnetEvent> eventController;

  setUp(() {
    mockClient = MockBacnetClient();
    eventController = StreamController<BacnetEvent>.broadcast();
    when(() => mockClient.events).thenAnswer((_) => eventController.stream);
    scanner = DeviceScanner(mockClient);
  });

  tearDown(() async {
    await eventController.close();
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
        when(
          () => mockClient.readMultiple(
            1234,
            any(),
            background: any(named: 'background'),
          ),
        ).thenAnswer(
          (_) async => {
            device(1234): {
              BacnetPropertyId.objectName: const BacnetCharacterString(
                'Test Device',
              ),
              BacnetPropertyId.vendorIdentifier: const BacnetUnsigned(99),
              BacnetPropertyId.vendorName: const BacnetCharacterString(
                'Test Vendor',
              ),
              BacnetPropertyId.modelName: const BacnetError(
                BacnetErrorClass.property,
                BacnetErrorCode.unknownProperty,
              ),
              BacnetPropertyId.segmentationSupported: const BacnetEnumerated(
                BacnetSegmentation.receive,
              ),
            },
          },
        );

        // Act
        final future = scanner.discoverDevices(
          timeout: const Duration(milliseconds: 100),
        );

        // Emit I-Am response
        eventController.add(
          const IAmEvent(deviceId: 1234, len: 0, mac: [], net: 0),
        );

        final devices = await future;

        // Assert
        expect(devices, hasLength(1));
        expect(devices.first.deviceId, 1234);
        expect(devices.first.deviceName, 'Test Device');
        expect(devices.first.vendorId, 99);
        expect(devices.first.vendorName, 'Test Vendor');
        expect(devices.first.modelName, isNull);
        expect(devices.first.segmentationSupported, BacnetSegmentation.receive);
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
        when(
          () => mockClient.readMultiple(
            10,
            any(),
            background: any(named: 'background'),
          ),
        ).thenAnswer(
          (_) async => {
            device(10): {
              BacnetPropertyId.objectName: const BacnetCharacterString(
                'Device 10',
              ),
            },
          },
        );
        when(
          () => mockClient.readMultiple(
            20,
            any(),
            background: any(named: 'background'),
          ),
        ).thenAnswer(
          (_) async => {
            device(20): {
              BacnetPropertyId.objectName: const BacnetCharacterString(
                'Device 20',
              ),
            },
          },
        );

        // Act
        final future = scanner.discoverDevices(
          timeout: const Duration(milliseconds: 100),
        );

        // Emit out of order
        eventController.add(
          const IAmEvent(deviceId: 20, len: 0, mac: [], net: 0),
        );
        eventController.add(
          const IAmEvent(deviceId: 10, len: 0, mac: [], net: 0),
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

        when(
          () => mockClient.readMultiple(
            10,
            any(),
            background: any(named: 'background'),
          ),
        ).thenAnswer(
          (_) async => {
            device(10): {
              BacnetPropertyId.objectName: const BacnetCharacterString(
                'Device 10',
              ),
            },
          },
        );

        // Act
        final future = scanner.discoverDevices(
          timeout: const Duration(milliseconds: 100),
        );

        eventController.add(
          const IAmEvent(deviceId: 10, len: 0, mac: [], net: 0),
        );
        eventController.add(
          const IAmEvent(deviceId: 10, len: 0, mac: [], net: 0),
        );

        final devices = await future;

        // Assert
        expect(devices, hasLength(1));
        verify(
          () => mockClient.readMultiple(
            10,
            any(),
            background: any(named: 'background'),
          ),
        ).called(1);
      });
    });

    group('scanDevice', () {
      test('scans objects and reads properties', () async {
        // Arrange
        const deviceId = 1234;
        const obj1 = BacnetObject(
          type: BacnetObjectType.analogInput,
          instance: 1,
        );
        const obj2 = BacnetObject(
          type: BacnetObjectType.analogOutput,
          instance: 2,
        );

        when(
          () => mockClient.scanDevice(
            deviceId,
            background: any(named: 'background'),
          ),
        ).thenAnswer((_) async => [obj1, obj2]);

        when(
          () => mockClient.readMultiple(
            deviceId,
            any(),
            background: any(named: 'background'),
          ),
        ).thenAnswer((invocation) async {
          // Verify batching logic via invocation arguments if needed
          // Return mock results
          return {
            obj1: {BacnetPropertyId.presentValue: const BacnetReal(100)},
            obj2: {BacnetPropertyId.presentValue: const BacnetReal(200)},
          };
        });

        // Act
        final results = await scanner.scanDevice(
          deviceId,
          propertyIds: [BacnetPropertyId.presentValue],
        );

        // Assert
        expect(results, hasLength(2));
        expect(
          results[obj1]?.valueOf(BacnetPropertyId.presentValue),
          const BacnetReal(100),
        );
        expect(
          results[obj2]?.valueOf(BacnetPropertyId.presentValue),
          const BacnetReal(200),
        );
      });
    });

    group('getDeviceDetails', () {
      test('throws Exception on connection failure', () async {
        // Arrange
        when(
          () => mockClient.readMultiple(
            any(),
            any(),
            background: any(named: 'background'),
          ),
        ).thenThrow(Exception('Connection failed'));

        // Act & Assert
        expect(() => scanner.getDeviceDetails(1234), throwsException);
      });
    });
  });
}
