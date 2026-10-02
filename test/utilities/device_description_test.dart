import 'dart:convert';
import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/testing.dart';
import 'package:test/test.dart';

void main() {
  const sensor = BacnetObject(type: BacnetObjectType.analogInput, instance: 1);
  const fan = BacnetObject(type: BacnetObjectType.binaryValue, instance: 2);

  late FakeBacnetDevice ahu;
  late FakeBacnetClient client;

  setUp(() async {
    ahu = FakeBacnetDevice(1234, name: 'AHU-1', vendorId: 7)
      ..addObject(
        BacnetObjectType.analogInput,
        1,
        name: 'Supply "air"',
        presentValue: const BacnetReal(21.5),
        units: BacnetEngineeringUnits.degreesCelsius,
      )
      ..addObject(
        BacnetObjectType.binaryValue,
        2,
        name: 'Fan',
        presentValue: const BacnetEnumerated(1),
      );
    client = FakeBacnetClient(devices: [ahu]);
    await client.start();
  });

  tearDown(() => client.close());

  test('reads every object with ReadPropertyMultiple ALL', () async {
    final progress = <(int, int)>[];
    final description = await client.describeDevice(
      1234,
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(description.deviceId, 1234);
    expect(description.deviceName, 'AHU-1');
    expect(description.objects.keys, [description.device, sensor, fan]);
    expect(
      description.objects[sensor]![BacnetPropertyId.presentValue],
      const BacnetReal(21.5),
    );
    expect(
      description.objects[description.device]![BacnetPropertyId.objectList],
      isA<BacnetList>(),
    );
    expect(progress.first, (0, 3));
    expect(progress.last, (3, 3));
    // only the object list, by the scan of the object list
    expect(
      client.requests
          .where((r) => r.service == 'readProperty')
          .map((r) => r.propertyId)
          .toSet(),
      {BacnetPropertyId.objectList},
    );
  });

  test(
    'reads devices without ReadPropertyMultiple property by property',
    () async {
      ahu.unsupportedServices.add(BacnetConfirmedService.readPropertyMultiple);
      ahu.object(
        BacnetObjectType.binaryValue,
        2,
      )![BacnetPropertyId.propertyList] = const BacnetList([
        BacnetEnumerated(85), // present-value
        BacnetEnumerated(111), // status-flags (missing: left out)
      ]);
      final description = await client.describeDevice(1234);
      expect(
        description.objects[sensor]![BacnetPropertyId.units],
        const BacnetEnumerated(62),
      );
      expect(description.objects[fan]!.keys, {
        BacnetPropertyId.objectIdentifier,
        BacnetPropertyId.objectName,
        BacnetPropertyId.objectType,
        BacnetPropertyId.presentValue,
      });
    },
  );

  test('stores as JSON', () async {
    final description = await client.describeDevice(1234);
    final restored = BacnetDeviceDescription.fromJson(
      jsonDecode(jsonEncode(description.toJson())) as Map<String, Object?>,
    );
    expect(restored, description);
    expect(restored.propertyCount, description.propertyCount);
    expect(
      () => BacnetDeviceDescription.fromJson(const {'deviceId': 1}),
      throwsFormatException,
    );
    expect(
      () => BacnetDeviceDescription.fromJson({
        'deviceId': 1,
        'time': '2026-10-02T10:00:00.000',
        'objects': [
          {
            'type': 0,
            'instance': 1,
            'properties': ['x'],
          },
        ],
      }),
      throwsFormatException,
    );
  });

  test('lists the objects like an EPICS', () {
    final description = BacnetDeviceDescription(
      deviceId: 1234,
      time: DateTime(2026, 10, 2),
      objects: {
        const BacnetObject(type: BacnetObjectType.device, instance: 1234): {
          BacnetPropertyId.objectName: const BacnetCharacterString('AHU-1'),
          BacnetPropertyId.segmentationSupported: const BacnetEnumerated(0),
        },
        sensor: {
          BacnetPropertyId.objectIdentifier: sensor,
          BacnetPropertyId.objectName: const BacnetCharacterString(
            r'Supply "air" \ 1',
          ),
          BacnetPropertyId.presentValue: const BacnetReal(21.5),
          BacnetPropertyId.units: const BacnetEnumerated(62),
          BacnetPropertyId.statusFlags: const BacnetBitString([
            false,
            true,
            false,
            false,
          ]),
          BacnetPropertyId.outOfService: const BacnetBoolean(false),
          BacnetPropertyId.priorityArray: const BacnetList([
            BacnetNull(),
            BacnetReal(1),
          ]),
        },
        fan: {
          BacnetPropertyId.presentValue: const BacnetEnumerated(1),
          BacnetPropertyId.eventState: const BacnetEnumerated(0),
          BacnetPropertyId.changeOfStateTime: const BacnetList([
            BacnetDate(year: 2026, month: 10, day: 1, weekday: 4),
            BacnetTime(hour: 8, minute: 5, second: 0, hundredths: 0),
          ]),
          BacnetPropertyId.profileName: BacnetOctetString(
            Uint8List.fromList([0xCA, 0xFE]),
          ),
          BacnetPropertyId.timeOfActiveTimeReset: const BacnetList([
            BacnetDate(),
            BacnetTime(hour: 23),
          ]),
        },
      },
    );
    final epics = description.toEpics();
    expect(epics, contains('List of Objects in Test Device:'));
    expect(epics, contains('device 1234 "AHU-1"'));
    for (final line in [
      'segmentation-supported: segmented-both',
      'object-identifier: (analog-input, 1)',
      r'object-name: "Supply \"air\" \\ 1"',
      'present-value: 21.5',
      'units: degrees-celsius',
      'status-flags: {F,T,F,F}',
      'out-of-service: FALSE',
      'priority-array: {NULL, 1.0}',
      'present-value: active',
      'event-state: normal',
      'change-of-state-time: {(Thursday, 1-October-2026), 08:05:00.00}',
      "profile-name: X'cafe'",
      'time-of-active-time-reset: {(*, *-*-*), 23:*:*.*}',
    ]) {
      expect(epics, contains('    $line\n'), reason: line);
    }
  });
}
