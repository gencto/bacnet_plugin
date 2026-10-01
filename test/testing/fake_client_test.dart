import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeBacnetDevice ahu;
  late FakeBacnetDevice boiler;
  late FakeBacnetClient client;

  setUp(() async {
    ahu = FakeBacnetDevice(1234, name: 'AHU-1', vendorId: 7)
      ..addObject(
        BacnetObjectType.analogInput,
        1,
        name: 'Supply Air Temperature',
        presentValue: 21.5,
        units: BacnetEngineeringUnits.degreesCelsius,
      )
      ..addObject(BacnetObjectType.analogOutput, 1, presentValue: 0)
      ..addObject(BacnetObjectType.binaryValue, 1, presentValue: false);
    boiler = FakeBacnetDevice(42, name: 'Boiler');
    client = FakeBacnetClient(devices: [ahu, boiler]);
    await client.start();
  });

  tearDown(() => client.close());

  test('discovers devices with DeviceScanner', () async {
    final devices = await DeviceScanner(
      client,
    ).discoverDevices(timeout: const Duration(milliseconds: 50));
    expect(devices.map((d) => d.deviceId), [42, 1234]);
    expect(devices.last.deviceName, 'AHU-1');
    expect(devices.last.vendorId, 7);
  });

  test('reads values like a real device', () async {
    expect(
      await client.readProperty(
        1234,
        BacnetObjectType.analogInput,
        1,
        BacnetPropertyId.presentValue,
      ),
      21.5,
    );
    final objects = await client.scanDevice(1234);
    expect(objects, hasLength(4));
    expect(
      await client.readProperty(
        1234,
        BacnetObjectType.device,
        1234,
        BacnetPropertyId.objectList,
        arrayIndex: 0,
      ),
      4,
    );
    final result = await client.readMultiple(1234, const [
      BacnetReadAccessSpecification(
        objectIdentifier: BacnetObject(
          type: BacnetObjectType.analogInput,
          instance: 1,
        ),
        properties: [
          BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.units),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.description,
          ),
        ],
      ),
    ]);
    expect(result['0:1']![BacnetPropertyId.units], 62);
    expect(
      result['0:1']![BacnetPropertyId.description],
      isA<BacnetError>().having(
        (e) => e.errorCode,
        'errorCode',
        BacnetErrorCode.unknownProperty,
      ),
    );
  });

  test('reports the errors of real devices', () async {
    await expectLater(
      client.readProperty(
        1234,
        BacnetObjectType.analogInput,
        99,
        BacnetPropertyId.presentValue,
      ),
      throwsA(
        isA<BacnetProtocolException>().having(
          (e) => e.errorCode,
          'errorCode',
          BacnetErrorCode.unknownObject,
        ),
      ),
    );
    await expectLater(
      client.readProperty(
        999,
        BacnetObjectType.device,
        999,
        BacnetPropertyId.objectName,
      ),
      throwsA(isA<BacnetDeviceNotFoundException>()),
    );
    boiler.online = false;
    await expectLater(
      client.readProperty(
        42,
        BacnetObjectType.device,
        42,
        BacnetPropertyId.objectName,
      ),
      throwsA(isA<BacnetTimeoutException>()),
    );
  });

  test('commands outputs through the priority array', () async {
    Future<Object?> value() => client.readProperty(
      1234,
      BacnetObjectType.analogOutput,
      1,
      BacnetPropertyId.presentValue,
    );
    Future<void> write(Object? value, int priority) => client.writeProperty(
      1234,
      BacnetObjectType.analogOutput,
      1,
      BacnetPropertyId.presentValue,
      value,
      priority: priority,
    );

    await write(50, 8);
    expect(await value(), 50.0);
    await write(30, 5);
    expect(await value(), 30.0);
    await write(null, 5);
    expect(await value(), 50.0);
    await write(null, 8);
    expect(await value(), 0.0, reason: 'relinquish default');

    await client.writeProperty(
      1234,
      BacnetObjectType.binaryValue,
      1,
      BacnetPropertyId.presentValue,
      true,
    );
    expect(
      await client.readProperty(
        1234,
        BacnetObjectType.binaryValue,
        1,
        BacnetPropertyId.presentValue,
      ),
      1,
    );
    expect(
      client.requests.where((r) => r.service == 'writeProperty'),
      hasLength(5),
    );
  });

  test('streams COV updates to PropertyMonitor', () async {
    final monitor = PropertyMonitor(client);
    final updates = <Object?>[];
    final subscription = monitor
        .monitorPresentValue(
          1234,
          const BacnetObject(type: BacnetObjectType.analogInput, instance: 1),
        )
        .listen((update) => updates.add(update.value));
    // wait until the monitor subscribed
    while (!client.requests.any((r) => r.service == 'subscribeCOV')) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));

    ahu.object(
      BacnetObjectType.analogInput,
      1,
    )![BacnetPropertyId.presentValue] = 22.0;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(updates, contains(22.0));
    await subscription.cancel();
  });

  test('simulates latency and cancellation', () async {
    client.latency = const Duration(milliseconds: 50);
    final token = BacnetCancelToken();
    final read = client.readProperty(
      1234,
      BacnetObjectType.analogInput,
      1,
      BacnetPropertyId.presentValue,
      cancelToken: token,
    );
    token.cancel();
    await expectLater(read, throwsA(isA<BacnetCancelledException>()));
  });

  test('serves trend log records', () async {
    final log = ahu.addObject(BacnetObjectType.trendLog, 1);
    for (var i = 0; i < 10; i++) {
      log.records.add(
        TrendLogEntry(
          timestamp: DateTime(2026, 1, 1, 0, i),
          value: i.toDouble(),
          status: 'OK',
        ),
      );
    }
    final data = await client.getTrendLog(1234, 1, count: 3);
    expect(data.entries.map((e) => e.value), [7.0, 8.0, 9.0]);
    expect(data.totalRecords, 10);
  });
}
