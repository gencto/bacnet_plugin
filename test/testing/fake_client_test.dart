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
        presentValue: const BacnetReal(21.5),
        units: BacnetEngineeringUnits.degreesCelsius,
      )
      ..addObject(BacnetObjectType.analogOutput, 1)
      ..addObject(BacnetObjectType.binaryValue, 1);
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
      const BacnetReal(21.5),
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
      const BacnetUnsigned(4),
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
    final properties = result[objects[1]]!;
    expect(
      properties[BacnetPropertyId.units],
      const BacnetEnumerated(BacnetEngineeringUnits.degreesCelsius),
    );
    expect(
      properties.errorOf(BacnetPropertyId.description)?.errorCode,
      BacnetErrorCode.unknownProperty,
    );
  });

  test('rejects properties requested twice like the real client', () {
    const spec = BacnetReadAccessSpecification(
      objectIdentifier: BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
      ),
      properties: [
        BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.units),
      ],
    );
    expect(
      () => client.readMultiple(1234, const [spec, spec]),
      throwsArgumentError,
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
    Future<BacnetValue> value() => client.readProperty(
      1234,
      BacnetObjectType.analogOutput,
      1,
      BacnetPropertyId.presentValue,
    );
    Future<void> write(BacnetValue value, int priority) => client.writeProperty(
      1234,
      BacnetObjectType.analogOutput,
      1,
      BacnetPropertyId.presentValue,
      value,
      priority: priority,
    );

    await write(const BacnetReal(50), 8);
    expect(await value(), const BacnetReal(50));
    await write(const BacnetReal(30), 5);
    expect(await value(), const BacnetReal(30));
    final priorities = await client.readProperty(
      1234,
      BacnetObjectType.analogOutput,
      1,
      BacnetPropertyId.priorityArray,
    );
    expect(priorities.asList[4], const BacnetReal(30));
    expect(priorities.asList[7], const BacnetReal(50));
    expect(priorities.asList[15], const BacnetNull());
    await write(const BacnetNull(), 5);
    expect(await value(), const BacnetReal(50));
    await write(const BacnetNull(), 8);
    expect(await value(), const BacnetReal(0), reason: 'relinquish default');

    await client.writeProperty(
      1234,
      BacnetObjectType.binaryValue,
      1,
      BacnetPropertyId.presentValue,
      const BacnetEnumerated(BacnetBinaryPV.active),
    );
    expect(
      await client.readProperty(
        1234,
        BacnetObjectType.binaryValue,
        1,
        BacnetPropertyId.presentValue,
      ),
      const BacnetEnumerated(1),
    );
    final writes = client.requests.where((r) => r.service == 'writeProperty');
    expect(writes, hasLength(5));
    expect(writes.first.value, const BacnetReal(50));
    expect(writes.first.priority, 8);
  });

  test('streams COV updates to PropertyMonitor', () async {
    final monitor = PropertyMonitor(client);
    final updates = <BacnetValue>[];
    final subscription = monitor
        .monitorPresentValue(
          1234,
          const BacnetObject(type: BacnetObjectType.analogInput, instance: 1),
        )
        .listen((update) {
          if (update case PropertyValueUpdate(:final value)) {
            updates.add(value);
          }
        });
    // wait until the monitor subscribed
    while (!client.requests.any((r) => r.service == 'subscribeCOV')) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));

    ahu.object(
      BacnetObjectType.analogInput,
      1,
    )![BacnetPropertyId.presentValue] = const BacnetReal(
      22,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(updates, contains(const BacnetReal(22)));
    await subscription.cancel();
  });

  test('reads and writes typed properties', () async {
    const output = BacnetObject(
      type: BacnetObjectType.analogOutput,
      instance: 1,
    );
    const sensor = BacnetObject(
      type: BacnetObjectType.analogInput,
      instance: 1,
    );
    expect(
      await client.read(1234, sensor, BacnetProperties.objectName),
      'Supply Air Temperature',
    );
    expect(
      await client.read(1234, sensor, BacnetProperties.units),
      BacnetEngineeringUnits.degreesCelsius,
    );
    await client.write(
      1234,
      output,
      BacnetProperties.analogPresentValue,
      42.5,
      priority: 8,
    );
    expect(
      await client.read(1234, output, BacnetProperties.analogPresentValue),
      42.5,
    );
    final priorities = await client.read(
      1234,
      output,
      BacnetProperties.priorityArray,
    );
    expect(priorities.activePriority, 8);
    await expectLater(
      client.read(1234, sensor, BacnetProperties.binaryPresentValue),
      throwsA(isA<BacnetDecodeException>()),
    );
  });

  test('answers Who-Has with I-Have', () async {
    final iHave = client.events.firstWhere((e) => e is IHaveEvent);
    await client.sendWhoHas(objectName: 'Supply Air Temperature');
    final event = await iHave as IHaveEvent;
    expect(event.deviceId, 1234);
    expect(
      event.object,
      const BacnetObject(type: BacnetObjectType.analogInput, instance: 1),
    );
    expect(client.requests.last.objectName, 'Supply Air Temperature');
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
          datum: TrendLogValue(BacnetReal(i.toDouble())),
        ),
      );
    }
    final data = await client.getTrendLog(1234, 1, count: 3);
    expect(data.entries.map((e) => e.value?.asDouble), [7.0, 8.0, 9.0]);
    expect(data.totalRecords, 10);
  });
}
