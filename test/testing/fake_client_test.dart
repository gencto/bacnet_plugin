import 'dart:typed_data';

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
    // an int for a REAL property
    await client.write(
      1234,
      output,
      BacnetProperties.analogPresentValue,
      40,
      priority: 7,
    );
    expect(
      await client.read(1234, output, BacnetProperties.analogPresentValue),
      40,
    );
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

  group('alarms', () {
    const notificationClass = BacnetObject(
      type: BacnetObjectType.notificationClass,
      instance: 1,
    );
    final destination = BacnetDestination(
      recipient: BacnetRecipient.ip('127.0.0.1', 47808),
      processId: 9,
    );
    late FakeBacnetObject sensor;

    setUp(() {
      ahu.addNotificationClass(1);
      sensor = ahu.object(BacnetObjectType.analogInput, 1)!
        ..enableEventReporting(notificationClass: 1);
    });

    Matcher protocolError(BacnetErrorCode code) => throwsA(
      isA<BacnetProtocolException>().having((e) => e.errorCode, 'code', code),
    );

    test('reports, summarizes and acknowledges alarms', () async {
      await client.addListElements(
        1234,
        notificationClass,
        BacnetProperties.recipientList,
        [destination],
      );
      // adding the same destination again changes nothing
      await client.addListElements(
        1234,
        notificationClass,
        BacnetProperties.recipientList,
        [destination],
      );
      expect(
        await client.read(
          1234,
          notificationClass,
          BacnetProperties.recipientList,
        ),
        [destination],
      );

      final alarmReceived = client.eventNotifications.first;
      sensor.reportEvent(
        BacnetEventState.highLimit,
        eventValues: const BacnetOutOfRangeValues(
          exceedingValue: 31,
          statusFlags: BacnetStatusFlags(inAlarm: true),
          deadband: 1,
          exceededLimit: 30,
        ),
        messageText: 'too hot',
      );
      final alarm = await alarmReceived;
      expect(alarm.processId, 9);
      expect(alarm.deviceId, 1234);
      expect(alarm.object, sensor.identifier);
      expect(alarm.eventType, BacnetEventType.outOfRange);
      expect(alarm.notifyType, BacnetNotifyType.alarm);
      expect(alarm.fromState, BacnetEventState.normal);
      expect(alarm.toState, BacnetEventState.highLimit);
      expect(alarm.ackRequired, isTrue);
      expect(alarm.priority, 100);
      expect(alarm.messageText, 'too hot');

      expect(
        await client.read(1234, sensor.identifier, BacnetProperties.eventState),
        BacnetEventState.highLimit,
      );
      expect(
        (await client.read(
          1234,
          sensor.identifier,
          BacnetProperties.statusFlags,
        )).inAlarm,
        isTrue,
      );
      final [summary] = await client.getEventInformation(1234);
      expect(summary.object, sensor.identifier);
      expect(summary.isUnacknowledged, isTrue);
      expect(summary.stateTimeStamp, alarm.timeStamp);
      expect(summary.eventPriorities, [100, 100, 200]);
      final [alarmSummary] = await client.getAlarmSummary(1234);
      expect(alarmSummary.alarmState, BacnetEventState.highLimit);

      await expectLater(
        client.acknowledgeAlarm(
          1234,
          sensor.identifier,
          BacnetEventState.highLimit,
          const BacnetTimeStampSequence(1),
          source: 'operator',
        ),
        protocolError(BacnetErrorCode.invalidTimeStamp),
      );

      final ackReceived = client.eventNotifications.first;
      await client.acknowledgeEvent(alarm, source: 'operator');
      final ack = await ackReceived;
      expect(ack.isAckNotification, isTrue);
      expect(ack.toState, BacnetEventState.highLimit);
      expect(client.requests.last.source, 'operator');
      expect(
        (await client.getEventInformation(1234)).single.isUnacknowledged,
        isFalse,
      );

      // TO-NORMAL needs no acknowledgement by default
      final normalReceived = client.eventNotifications.first;
      sensor.reportEvent(BacnetEventState.normal);
      final normal = await normalReceived;
      expect(normal.ackRequired, isFalse);
      expect(normal.fromState, BacnetEventState.highLimit);
      expect(await client.getEventInformation(1234), isEmpty);
      expect(await client.getAlarmSummary(1234), isEmpty);
      await expectLater(
        client.acknowledgeEvent(alarm, source: 'operator'),
        protocolError(BacnetErrorCode.invalidEventState),
      );
    });

    test('removes recipients', () async {
      await client.addListElements(
        1234,
        notificationClass,
        BacnetProperties.recipientList,
        [destination],
      );
      await client.removeListElements(
        1234,
        notificationClass,
        BacnetProperties.recipientList,
        [destination],
      );
      expect(
        await client.read(
          1234,
          notificationClass,
          BacnetProperties.recipientList,
        ),
        isEmpty,
      );
      await expectLater(
        client.removeListElements(
          1234,
          notificationClass,
          BacnetProperties.recipientList,
          [destination],
        ),
        protocolError(BacnetErrorCode.listElementNotFound),
      );

      var received = 0;
      final subscription = client.eventNotifications.listen((_) => received++);
      sensor.reportEvent(BacnetEventState.lowLimit);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await subscription.cancel();
      expect(received, 0);
      expect(sensor.eventState, BacnetEventState.lowLimit);
    });

    test('subscribes with subscribeAlarms', () async {
      final me = await client.localAddress();
      expect(me.ipAddress, '127.0.0.1');
      expect(me.port, client.config.port);

      final alarms = await client.subscribeAlarms(1234, notificationClass: 1);
      expect(alarms.destination.recipient, me);
      expect(
        await client.read(
          1234,
          notificationClass,
          BacnetProperties.recipientList,
        ),
        [alarms.destination],
      );
      // another class of the device is not part of the subscription
      ahu.addNotificationClass(2);
      final other = ahu.addObject(BacnetObjectType.analogValue, 9)
        ..enableEventReporting(notificationClass: 2);
      await client.subscribeAlarms(1234, notificationClass: 2);

      final received = alarms.notifications.first;
      other.reportEvent(BacnetEventState.highLimit);
      sensor.reportEvent(BacnetEventState.lowLimit);
      final event = await received;
      expect(event.object, sensor.identifier);
      expect(event.processId, alarms.destination.processId);
      expect(await alarms.eventInformation(), hasLength(2));

      // the device lost its recipients
      ahu.object(
        BacnetObjectType.notificationClass,
        1,
      )![BacnetPropertyId.recipientList] = const BacnetList(
        [],
      );
      expect(await alarms.refresh(), isTrue);
      expect(await alarms.refresh(), isFalse);

      await alarms.cancel();
      expect(alarms.isCancelled, isTrue);
      expect(
        await client.read(
          1234,
          notificationClass,
          BacnetProperties.recipientList,
        ),
        isEmpty,
      );
      await alarms.cancel(); // once only
      expect(alarms.refresh, throwsStateError);
    });

    test('subscribes with WriteProperty without AddListElement', () async {
      ahu.unsupportedServices.addAll([
        BacnetConfirmedService.addListElement,
        BacnetConfirmedService.removeListElement,
      ]);
      await expectLater(
        client.addListElements(
          1234,
          notificationClass,
          BacnetProperties.recipientList,
          [destination],
        ),
        throwsA(
          isA<BacnetRejectException>().having(
            (e) => e.reason,
            'reason',
            BacnetRejectReason.unrecognizedService,
          ),
        ),
      );
      final alarms = await client.subscribeAlarms(
        1234,
        notificationClass: 1,
        processId: 77,
        confirmed: true,
      );
      expect(
        await client.read(
          1234,
          notificationClass,
          BacnetProperties.recipientList,
        ),
        [alarms.destination],
      );
      final received = alarms.notifications.first;
      sensor.reportEvent(BacnetEventState.highLimit);
      final event = await received;
      expect(event.processId, 77);
      expect(event.confirmed, isTrue);
      await alarms.cancel();
      expect(
        await client.read(
          1234,
          notificationClass,
          BacnetProperties.recipientList,
        ),
        isEmpty,
      );
      expect(
        client.requests.map((r) => r.service),
        containsAllInOrder([
          'addListElement',
          'readProperty',
          'writeProperty',
          'removeListElement',
          'readProperty',
          'writeProperty',
        ]),
      );
    });

    test('requires event reporting to be enabled', () {
      final output = ahu.object(BacnetObjectType.analogOutput, 1)!;
      expect(
        () => output.reportEvent(BacnetEventState.fault),
        throwsStateError,
      );
    });
  });

  group('device management', () {
    Matcher protocolError(BacnetErrorCode code, {int? element}) => throwsA(
      isA<BacnetProtocolException>()
          .having((e) => e.errorCode, 'code', code)
          .having((e) => e.firstFailedElement, 'element', element),
    );

    test('DeviceCommunicationControl silences the device', () async {
      ahu.password = 'secret';
      await expectLater(
        client.deviceCommunicationControl(
          1234,
          BacnetCommunicationState.disable,
        ),
        protocolError(BacnetErrorCode.passwordFailure),
      );
      await client.deviceCommunicationControl(
        1234,
        BacnetCommunicationState.disable,
        password: 'secret',
        duration: const Duration(minutes: 1),
      );
      expect(ahu.communication, BacnetCommunicationState.disable);
      await expectLater(
        client.readProperty(
          1234,
          BacnetObjectType.device,
          1234,
          BacnetPropertyId.objectName,
        ),
        throwsA(isA<BacnetTimeoutException>()),
      );
      final devices = await DeviceScanner(
        client,
      ).discoverDevices(timeout: const Duration(milliseconds: 50));
      expect(devices.map((d) => d.deviceId), [42]);

      await client.deviceCommunicationControl(
        1234,
        BacnetCommunicationState.enable,
        password: 'secret',
      );
      expect(
        await client.read(
          1234,
          const BacnetObject(type: BacnetObjectType.device, instance: 1234),
          BacnetProperties.objectName,
        ),
        'AHU-1',
      );
    });

    test('ReinitializeDevice is recorded', () async {
      await client.reinitializeDevice(1234, BacnetReinitializedState.warmStart);
      expect(ahu.reinitializations, [BacnetReinitializedState.warmStart]);
    });

    test('creates and deletes objects', () async {
      final created = await client.createObject(
        1234,
        type: BacnetObjectType.analogValue,
        initialValues: const [
          BacnetPropertyValue(
            propertyIdentifier: BacnetPropertyId.objectName,
            value: BacnetCharacterString('Setpoint'),
          ),
          BacnetPropertyValue(
            propertyIdentifier: BacnetPropertyId.presentValue,
            value: BacnetReal(21.5),
          ),
        ],
      );
      expect(
        created,
        const BacnetObject(type: BacnetObjectType.analogValue, instance: 1),
      );
      expect(
        await client.read(1234, created, BacnetProperties.objectName),
        'Setpoint',
      );
      expect(
        await client.read(1234, created, BacnetProperties.analogPresentValue),
        21.5,
      );
      expect(await client.scanDevice(1234), contains(created));
      await expectLater(
        client.createObject(1234, object: created),
        protocolError(
          BacnetErrorCode.objectIdentifierAlreadyExists,
          element: 0,
        ),
      );
      await expectLater(
        client.createObject(
          1234,
          type: BacnetObjectType.analogValue,
          initialValues: const [
            BacnetPropertyValue(
              propertyIdentifier: BacnetPropertyId.description,
              value: BacnetCharacterString('ok'),
            ),
            BacnetPropertyValue(
              propertyIdentifier: BacnetPropertyId.objectType,
              value: BacnetEnumerated(BacnetObjectType.binaryValue),
            ),
          ],
        ),
        protocolError(BacnetErrorCode.writeAccessDenied, element: 2),
      );

      await client.deleteObject(1234, created);
      expect(await client.scanDevice(1234), isNot(contains(created)));
      await expectLater(
        client.deleteObject(1234, created),
        protocolError(BacnetErrorCode.unknownObject),
      );
      await expectLater(
        client.deleteObject(
          1234,
          const BacnetObject(type: BacnetObjectType.device, instance: 1234),
        ),
        protocolError(BacnetErrorCode.objectDeletionNotPermitted),
      );
    });

    test('reads and writes files', () async {
      final content = Uint8List.fromList(
        List.generate(5000, (i) => i * 7 & 0xFF),
      );
      final file = ahu.addFile(1, content: content, name: 'config.bin');
      final progress = <(int, int?)>[];
      final read = await client.readFile(
        1234,
        1,
        onProgress: (done, total) => progress.add((done, total)),
      );
      expect(read, content);
      // 1476 octets of maximum APDU: chunks of 1444 octets
      expect(progress.map((p) => p.$1), [0, 1444, 2888, 4332, 5000]);
      expect(progress.every((p) => p.$2 == 5000), isTrue);
      expect(
        client.requests.where((r) => r.service == 'readFileStream'),
        hasLength(4),
      );

      final chunk = await client.readFileStream(
        1234,
        1,
        start: 4990,
        count: 100,
      );
      expect(chunk.start, 4990);
      expect(chunk.data, content.sublist(4990));
      expect(chunk.endOfFile, isTrue);

      await client.writeFile(1234, 1, [1, 2, 3], truncate: true);
      expect(file.fileContent, [1, 2, 3]);
      expect(
        await client.readProperty(
          1234,
          BacnetObjectType.file,
          1,
          BacnetPropertyId.fileSize,
        ),
        const BacnetUnsigned(3),
      );
      expect(await client.writeFileStream(1234, 1, [4, 5], start: -1), 3);
      expect(await client.readFile(1234, 1), [1, 2, 3, 4, 5]);

      await expectLater(
        client.readFileStream(1234, 1, start: 99, count: 1),
        protocolError(BacnetErrorCode.invalidFileStartPosition),
      );
      await expectLater(
        client.readFileRecords(1234, 1, start: 0, count: 1),
        protocolError(BacnetErrorCode.invalidFileAccessMethod),
      );
      await expectLater(
        client.readFile(1234, 9),
        throwsA(isA<BacnetProtocolException>()),
      );
      ahu.addFile(2, readOnly: true);
      await expectLater(
        client.writeFile(1234, 2, [1]),
        protocolError(BacnetErrorCode.fileAccessDenied),
      );
    });

    test('ConfirmedPrivateTransfer calls the vendor handler', () async {
      await expectLater(
        client.privateTransfer(1234, 260, 1),
        throwsA(isA<BacnetRejectException>()),
      );
      ahu.onPrivateTransfer = (vendor, service, parameters) =>
          BacnetList([BacnetUnsigned(vendor), BacnetUnsigned(service)]);
      expect(
        await client.privateTransfer(1234, 260, 7),
        const BacnetList([BacnetUnsigned(260), BacnetUnsigned(7)]),
      );
    });

    test('text messages reach devices', () async {
      await client.textMessage(1234, 'Filter change due', urgent: true);
      await client.sendTextMessage('Shutdown at 18:00');
      expect(ahu.messages.map((m) => m.message), [
        'Filter change due',
        'Shutdown at 18:00',
      ]);
      expect(ahu.messages.first.urgent, isTrue);
      expect(boiler.messages.single.message, 'Shutdown at 18:00');
    });
  });
}
