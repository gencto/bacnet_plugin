@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

import '../support/cov_multiple_device.dart';
import '../support/fake_router.dart';
import '../support/segmenting_device.dart';

/// Runs tool/demo_server.dart in a separate process (the native stack is
/// process global, so client and server need separate processes).
class ServerProcess {
  ServerProcess._(this.process, this.lines);

  final Process process;
  final List<String> lines;

  static Future<ServerProcess> start(int port, int device, int objects) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'tool/demo_server.dart', '$port', '$device', '$objects'],
      environment: {'BACNET_IFACE': '127.0.0.1'},
    );
    final lines = <String>[];
    final ready = Completer<void>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          lines.add(line);
          if (line.startsWith('READY') && !ready.isCompleted) ready.complete();
        });
    process.stderr.transform(utf8.decoder).listen(lines.add);
    unawaited(
      process.exitCode.then((code) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('server exited ($code): $lines'));
        }
      }),
    );
    await ready.future.timeout(const Duration(minutes: 3));
    return ServerProcess._(process, lines);
  }

  /// Writes a command line to the server (see tool/demo_server.dart).
  void send(String line) => process.stdin.writeln(line);

  Future<void> stop() async {
    process.kill();
    await process.exitCode;
  }
}

void main() {
  const serverPort = 47861;
  const device = 7001;
  late ServerProcess server;
  late BacnetClient client;

  setUpAll(() async {
    server = await ServerProcess.start(serverPort, device, 100);
    client = BacnetClient(
      config: const BacnetConfig(
        interface: '127.0.0.1',
        port: 47862,
        requestTimeout: Duration(seconds: 10),
        // short segment timeout (4 APDU timeouts) for the segmentation tests
        apduTimeout: Duration(milliseconds: 500),
        bindTimeout: Duration(seconds: 1),
        logLevel: BacnetLogLevel.warning,
      ),
    );
    await client.start();
    await client.addDeviceBinding(device, '127.0.0.1', port: serverPort);
  });

  tearDownAll(() async {
    await client.close();
    await server.stop();
  });

  test('reads device and object properties', () async {
    expect(client.nativeVersion, contains('bacnet-stack/'));
    expect(
      await client.readProperty(
        device,
        BacnetObjectType.device,
        device,
        BacnetPropertyId.objectName,
      ),
      const BacnetCharacterString('DemoServer'),
    );
    final value = await client.readProperty(
      device,
      BacnetObjectType.analogValue,
      50,
      BacnetPropertyId.presentValue,
    );
    expect(value, const BacnetReal(50));
    expect(
      await client.readProperty(
        device,
        BacnetObjectType.multiStateValue,
        0,
        BacnetPropertyId.stateText,
      ),
      const BacnetList([
        BacnetCharacterString('Off'),
        BacnetCharacterString('On'),
        BacnetCharacterString('Auto'),
      ]),
    );
    expect(
      await client.readProperty(
        device,
        BacnetObjectType.analogValue,
        50,
        BacnetPropertyId.units,
      ),
      const BacnetEnumerated(BacnetEngineeringUnits.degreesCelsius),
    );
  });

  test('reads and writes typed properties', () async {
    const av = BacnetObject(type: BacnetObjectType.analogValue, instance: 80);
    expect(await client.read(device, av, BacnetProperties.objectName), 'AV-80');
    expect(
      await client.read(device, av, BacnetProperties.units),
      BacnetEngineeringUnits.degreesCelsius,
    );
    expect(
      await client.read(device, av, BacnetProperties.statusFlags),
      const BacnetStatusFlags(),
    );
    await client.write(
      device,
      av,
      BacnetProperties.analogPresentValue,
      55.5,
      priority: 9,
    );
    expect(
      await client.read(device, av, BacnetProperties.analogPresentValue),
      55.5,
    );
    const deviceObject = BacnetObject(
      type: BacnetObjectType.device,
      instance: device,
    );
    final objects = await client.read(
      device,
      deviceObject,
      BacnetProperties.objectList,
    );
    expect(objects, hasLength(119));
    expect(
      await client.read(device, deviceObject, BacnetProperties.vendorName),
      'bacnet_plugin',
    );
  });

  test('scans the object list', () async {
    final objects = await client.scanDevice(device);
    // device, network port, 100 AV, BV, MSV, alarms: NC, AV, BV, 2 files,
    // scheduled AV, calendar, schedule, 2 logged AVs, 2 trend logs,
    // settings file, grouped AV, channel
    expect(objects, hasLength(119));
    final scanner = DeviceScanner(client);
    final details = await scanner.getDeviceDetails(device);
    expect(details.deviceName, 'DemoServer');
    expect(details.vendorName, 'bacnet_plugin');
  });

  test('describes the device', () async {
    final description = await client.describeDevice(device);
    expect(description.objects, hasLength(119));
    expect(description.deviceName, 'DemoServer');
    const av50 = BacnetObject(type: BacnetObjectType.analogValue, instance: 50);
    expect(
      description.objects[av50],
      containsPair(BacnetPropertyId.presentValue, const BacnetReal(50)),
    );
    expect(description.objects[av50], contains(BacnetPropertyId.covIncrement));
    final epics = description.toEpics();
    expect(epics, contains('    object-name: "AV-50"\n'));
    expect(epics, contains('    units: degrees-celsius\n'));
  });

  test('ReadPropertyMultiple returns values and errors', () async {
    final result = await client.readMultiple(device, const [
      BacnetReadAccessSpecification(
        objectIdentifier: BacnetObject(
          type: BacnetObjectType.analogValue,
          instance: 60,
        ),
        properties: [
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.objectName,
          ),
          BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.units),
          BacnetPropertyReference(propertyIdentifier: BacnetPropertyId(9999)),
        ],
      ),
    ]);
    final av60 =
        result[const BacnetObject(
          type: BacnetObjectType.analogValue,
          instance: 60,
        )]!;
    expect(
      av60[BacnetPropertyId.objectName],
      const BacnetCharacterString('AV-60'),
    );
    expect(
      av60[BacnetPropertyId.units],
      const BacnetEnumerated(BacnetEngineeringUnits.degreesCelsius),
    );
    expect(
      av60.errorOf(const BacnetPropertyId(9999))?.errorCode,
      BacnetErrorCode.unknownProperty,
    );
  });

  test('large ReadPropertyMultiple requests are split', () async {
    final result = await client.readMultiple(device, [
      for (var i = 0; i < 100; i++)
        BacnetReadAccessSpecification(
          objectIdentifier: BacnetObject(
            type: BacnetObjectType.analogValue,
            instance: i,
          ),
          properties: const [
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.objectName,
            ),
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.description,
            ),
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.statusFlags,
            ),
          ],
        ),
    ]);
    expect(result, hasLength(100));
    expect(
      result[const BacnetObject(
            type: BacnetObjectType.analogValue,
            instance: 99,
          )]!
          .valueOf(BacnetPropertyId.objectName),
      const BacnetCharacterString('AV-99'),
    );
  });

  test('writes typed values', () async {
    int writeEvents() =>
        server.lines.where((l) => l.startsWith('WRITE')).length;
    final writesBefore = writeEvents();
    await client.writeProperty(
      device,
      BacnetObjectType.analogValue,
      70,
      BacnetPropertyId.presentValue,
      const BacnetReal(12.5),
      priority: 8,
    );
    expect(
      await client.readProperty(
        device,
        BacnetObjectType.analogValue,
        70,
        BacnetPropertyId.presentValue,
      ),
      const BacnetReal(12.5),
    );
    await client.writeProperty(
      device,
      BacnetObjectType.binaryValue,
      0,
      BacnetPropertyId.presentValue,
      const BacnetEnumerated(BacnetBinaryPV.active),
    );
    expect(
      await client.readProperty(
        device,
        BacnetObjectType.binaryValue,
        0,
        BacnetPropertyId.presentValue,
      ),
      const BacnetEnumerated(BacnetBinaryPV.active),
    );
    await client.writeMultiple(device, const [
      BacnetWriteAccessSpecification(
        objectIdentifier: BacnetObject(
          type: BacnetObjectType.multiStateValue,
          instance: 0,
        ),
        listOfProperties: [
          BacnetPropertyValue(
            propertyIdentifier: BacnetPropertyId.presentValue,
            value: BacnetUnsigned(3),
          ),
        ],
      ),
    ]);
    expect(
      await client.readProperty(
        device,
        BacnetObjectType.multiStateValue,
        0,
        BacnetPropertyId.presentValue,
      ),
      const BacnetUnsigned(3),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(writeEvents() - writesBefore, 3);
  });

  test('reports protocol errors with typed exceptions', () async {
    await expectLater(
      client.readProperty(
        device,
        BacnetObjectType.analogValue,
        4000,
        BacnetPropertyId.presentValue,
      ),
      throwsA(
        isA<BacnetProtocolException>().having(
          (e) => e.errorCode,
          'code',
          BacnetErrorCode.unknownObject,
        ),
      ),
    );
    await expectLater(
      client.writeProperty(
        device,
        BacnetObjectType.multiStateValue,
        0,
        BacnetPropertyId.presentValue,
        const BacnetUnsigned(9),
      ),
      throwsA(isA<BacnetProtocolException>()),
    );
    await expectLater(
      client.readProperty(
        4000000,
        BacnetObjectType.analogValue,
        1,
        BacnetPropertyId.presentValue,
      ),
      throwsA(isA<BacnetDeviceNotFoundException>()),
    );
  });

  test('handles thousands of concurrent requests', () async {
    final results = await Future.wait([
      for (var i = 0; i < 5000; i++)
        client.readProperty(
          device,
          BacnetObjectType.analogValue,
          i % 100,
          BacnetPropertyId.objectName,
        ),
    ]);
    for (var i = 0; i < results.length; i++) {
      expect(results[i], BacnetCharacterString('AV-${i % 100}'));
    }
    final stats = await client.stats();
    expect(stats.inFlightRequests, 0);
    expect(stats.queuedRequests, 0);
    expect(stats.repliesDropped, 0);
  });

  test('merges concurrent reads into ReadPropertyMultiple', () async {
    final before = await client.stats();
    final reads = [
      for (var i = 0; i < 48; i++)
        client.readProperty(
          device,
          BacnetObjectType.analogValue,
          i,
          BacnetPropertyId.presentValue,
        ),
      client.readProperty(
        device,
        BacnetObjectType.analogValue,
        1,
        BacnetPropertyId.objectName,
      ),
      client.readProperty(
        device,
        BacnetObjectType.analogValue,
        1,
        const BacnetPropertyId(9999),
      ),
    ];
    final settled = await Future.wait([
      for (final read in reads)
        read.then<Object?>((value) => value, onError: (Object e) => e),
    ]);
    expect(settled[48], const BacnetCharacterString('AV-1'));
    expect(
      settled[49],
      isA<BacnetProtocolException>().having(
        (e) => e.errorCode,
        'errorCode',
        BacnetErrorCode.unknownProperty,
      ),
    );
    final after = await client.stats();
    // 50 reads in batches of 24 properties
    expect(after.requestsSent - before.requestsSent, 3);
  });

  test('cancels requests', () async {
    Future<List<Object?>> settle(Iterable<Future<Object?>> futures) =>
        Future.wait([
          for (final f in futures)
            f.then<Object?>((value) => value, onError: (Object e) => e),
        ]);
    final token = BacnetCancelToken();
    final reads = [
      for (var i = 0; i < 100; i++)
        client.readProperty(
          device,
          BacnetObjectType.analogValue,
          i,
          BacnetPropertyId.objectName,
          cancelToken: token,
        ),
      for (var i = 0; i < 100; i++)
        client.readMultiple(
          device,
          [
            BacnetReadAccessSpecification(
              objectIdentifier: BacnetObject(
                type: BacnetObjectType.analogValue,
                instance: i,
              ),
              properties: const [
                BacnetPropertyReference(
                  propertyIdentifier: BacnetPropertyId.presentValue,
                ),
              ],
            ),
          ],
          background: true,
          cancelToken: token,
        ),
    ];
    token.cancel();
    final results = await settle(reads);
    expect(results.whereType<BacnetCancelledException>(), hasLength(200));

    // the client keeps working and nothing is left in the queue
    expect(
      await client.readProperty(
        device,
        BacnetObjectType.analogValue,
        1,
        BacnetPropertyId.objectName,
      ),
      const BacnetCharacterString('AV-1'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final stats = await client.stats();
    expect(stats.queuedRequests, 0);
    expect(stats.inFlightRequests, 0);
  });

  group('segmented answers', () {
    var nextDevice = 7100;

    Future<SegmentingDevice> device({
      Set<int> dropOnce = const {},
      int? stallAfter,
    }) async {
      final device = await SegmentingDevice.bind(
        deviceId: nextDevice++,
        dropOnce: dropOnce,
        stallAfter: stallAfter,
      );
      addTearDown(device.close);
      await client.addDeviceBinding(
        device.deviceId,
        '127.0.0.1',
        port: device.port,
      );
      return device;
    }

    Future<BacnetValue> readObjectList(SegmentingDevice device) =>
        client.readProperty(
          device.deviceId,
          BacnetObjectType.device,
          device.deviceId,
          BacnetPropertyId.objectList,
        );

    test('are reassembled', () async {
      final fake = await device();
      final before = await client.stats();
      final list = (await readObjectList(fake)).asList;
      expect(list, hasLength(300));
      expect(
        list[299],
        const BacnetObject(type: BacnetObjectType.analogValue, instance: 299),
      );
      expect(fake.segmentationAccepted, [true]);
      // first segment, then every window of 3, then the last one (8 segments)
      expect(fake.acks, [(false, 0), (false, 3), (false, 6), (false, 7)]);
      final after = await client.stats();
      expect(after.segmentedReplies - before.segmentedReplies, 1);
    });

    test('ask again for lost segments', () async {
      final fake = await device(dropOnce: {4});
      final list = await readObjectList(fake);
      expect(list.asList, hasLength(300));
      expect(fake.acks, contains((true, 3)));
    });

    test('time out when the device stops sending', () async {
      final fake = await device(stallAfter: 2);
      await expectLater(
        readObjectList(fake),
        throwsA(isA<BacnetTimeoutException>()),
      );
      final stats = await client.stats();
      expect(stats.inFlightRequests, 0);
    });
  });

  test('receives COV notifications with values', () async {
    final notifications = <CovNotificationEvent>[];
    final subscription = client.covEvents.listen(notifications.add);
    await client.subscribeCOV(
      device,
      BacnetObjectType.analogValue,
      1,
      processId: 99,
      lifetime: const Duration(seconds: 30),
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    await client.unsubscribeCOV(
      device,
      BacnetObjectType.analogValue,
      1,
      processId: 99,
    );
    await subscription.cancel();
    expect(notifications, isNotEmpty);
    expect(notifications.first.deviceId, device);
    expect(notifications.first.presentValue, isA<BacnetReal>());
    expect(notifications.first.statusFlags, isNotNull);
  });

  test('PropertyMonitor streams COV updates', () async {
    final monitor = PropertyMonitor(client);
    final updates = await monitor
        .monitorPresentValue(
          device,
          const BacnetObject(type: BacnetObjectType.analogValue, instance: 2),
        )
        .take(3)
        .toList()
        .timeout(const Duration(seconds: 10));
    expect(updates.first.source, UpdateSource.manual);
    expect(updates.last.source, UpdateSource.cov);
  });

  group('alarms and events', () {
    const notificationClass = BacnetObject(
      type: BacnetObjectType.notificationClass,
      instance: 1,
    );
    const alarmAv = BacnetObject(
      type: BacnetObjectType.analogValue,
      instance: 100,
    );
    const alarmBv = BacnetObject(
      type: BacnetObjectType.binaryValue,
      instance: 1,
    );
    final unconfirmed = BacnetDestination(
      recipient: BacnetRecipient.ip('127.0.0.1', 47862),
      processId: 42,
    );
    final confirmed = BacnetDestination(
      recipient: BacnetRecipient.ip('127.0.0.1', 47862),
      processId: 43,
      issueConfirmedNotifications: true,
    );

    Future<EventNotificationEvent> next(
      bool Function(EventNotificationEvent) test,
    ) => client.eventNotifications
        .firstWhere(test)
        .timeout(const Duration(seconds: 10));

    /// The first line of the server output matching [test].
    Future<String> serverLine(bool Function(String) test) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        for (final line in server.lines) {
          if (test(line)) return line;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      throw TimeoutException('no matching server output');
    }

    Future<List<BacnetDestination>> recipients() =>
        client.read(device, notificationClass, BacnetProperties.recipientList);

    test('reports alarms to recipients and takes acknowledgements', () async {
      expect(
        await client.read(
          device,
          notificationClass,
          BacnetProperties.objectName,
        ),
        'Alarms',
      );
      await client.addListElements(
        device,
        notificationClass,
        BacnetProperties.recipientList,
        [unconfirmed],
      );
      expect(await recipients(), [unconfirmed]);
      expect(
        await serverLine((l) => l.startsWith('LIST') && l.contains('added to')),
        contains('Recipient List'),
      );

      // the value exceeds the high limit
      final alarmReceived = next(
        (e) => e.object == alarmAv && e.toState == BacnetEventState.highLimit,
      );
      await client.write(
        device,
        alarmAv,
        BacnetProperties.analogPresentValue,
        35,
        priority: 8,
      );
      final alarm = await alarmReceived;
      expect(alarm.processId, 42);
      expect(alarm.confirmed, isFalse);
      expect(alarm.deviceId, device);
      expect(alarm.notificationClass, 1);
      expect(alarm.priority, 100);
      expect(alarm.eventType, BacnetEventType.outOfRange);
      expect(alarm.notifyType, BacnetNotifyType.alarm);
      expect(alarm.ackRequired, isTrue);
      expect(alarm.fromState, BacnetEventState.normal);
      expect(alarm.timeStamp, isA<BacnetTimeStampDateTime>());
      switch (alarm.eventValues) {
        case BacnetOutOfRangeValues(
          :final exceedingValue,
          :final exceededLimit,
          :final deadband,
          :final statusFlags,
        ):
          expect(exceedingValue, 35);
          expect(exceededLimit, 30);
          expect(deadband, 1);
          expect(statusFlags.inAlarm, isTrue);
        default:
          fail('unexpected values ${alarm.eventValues}');
      }

      final summary = (await client.getEventInformation(
        device,
      )).firstWhere((s) => s.object == alarmAv);
      expect(summary.eventState, BacnetEventState.highLimit);
      expect(summary.isUnacknowledged, isTrue);
      expect(summary.stateTimeStamp, alarm.timeStamp);
      expect(
        (await client.getAlarmSummary(device)).map((s) => s.object),
        contains(alarmAv),
      );
      expect(
        await client.read(device, alarmAv, BacnetProperties.eventState),
        BacnetEventState.highLimit,
      );

      // acknowledging sends an acknowledgement notification
      final ackReceived = next(
        (e) => e.object == alarmAv && e.isAckNotification,
      );
      await client.acknowledgeEvent(alarm, source: 'integration test');
      expect((await ackReceived).toState, BacnetEventState.highLimit);
      expect(
        await serverLine((l) => l.startsWith('ACK')),
        allOf(contains('High Limit'), contains('"integration test"')),
      );
      expect(
        (await client.getEventInformation(
          device,
        )).firstWhere((s) => s.object == alarmAv).isUnacknowledged,
        isFalse,
      );
      await expectLater(
        client.acknowledgeAlarm(
          device,
          alarmAv,
          BacnetEventState.lowLimit,
          alarm.timeStamp,
          source: 'integration test',
        ),
        throwsA(isA<BacnetProtocolException>()),
      );

      // back inside the limits
      final normalReceived = next(
        (e) => e.object == alarmAv && e.toState == BacnetEventState.normal,
      );
      await client.write(
        device,
        alarmAv,
        BacnetProperties.analogPresentValue,
        20,
        priority: 8,
      );
      final normal = await normalReceived;
      expect(normal.fromState, BacnetEventState.highLimit);
      expect(normal.ackRequired, isFalse);
      expect(normal.priority, 200);
      expect(
        (await client.getAlarmSummary(device)).map((s) => s.object),
        isNot(contains(alarmAv)),
      );
    });

    test('sends confirmed notifications of binary objects', () async {
      // bacnet-stack keeps one destination per recipient: this one
      // replaces the unconfirmed destination
      await client.addListElements(
        device,
        notificationClass,
        BacnetProperties.recipientList,
        [confirmed],
      );
      expect(await recipients(), [confirmed]);

      final eventReceived = next(
        (e) => e.object == alarmBv && e.toState == BacnetEventState.offNormal,
      );
      await client.write(
        device,
        alarmBv,
        BacnetProperties.binaryPresentValue,
        BacnetBinaryPV.active,
      );
      final event = await eventReceived;
      expect(event.confirmed, isTrue);
      expect(event.processId, 43);
      expect(event.eventType, BacnetEventType.changeOfState);
      expect(event.notifyType, BacnetNotifyType.event);
      switch (event.eventValues) {
        case BacnetChangeOfStateValues(:final newState):
          expect(newState.asBinaryPV, BacnetBinaryPV.active);
        default:
          fail('unexpected values ${event.eventValues}');
      }
      final normalReceived = next(
        (e) => e.object == alarmBv && e.toState == BacnetEventState.normal,
      );
      await client.write(
        device,
        alarmBv,
        BacnetProperties.binaryPresentValue,
        BacnetBinaryPV.inactive,
      );
      await normalReceived;
    });

    test('removes recipients', () async {
      await client.removeListElements(
        device,
        notificationClass,
        BacnetProperties.recipientList,
        [confirmed],
      );
      expect(await recipients(), isEmpty);
      expect(
        await serverLine(
          (l) => l.startsWith('LIST') && l.contains('removed from'),
        ),
        contains('Recipient List'),
      );
    });
    test('subscribes with subscribeAlarms', () async {
      final me = await client.localAddress();
      expect(me.ipAddress, '127.0.0.1');
      expect(me.port, 47862);
      final alarms = await client.subscribeAlarms(
        device,
        notificationClass: 1,
        processId: 44,
      );
      expect(await recipients(), contains(alarms.destination));
      final received = alarms.notifications
          .firstWhere((e) => e.object == alarmAv)
          .timeout(const Duration(seconds: 10));
      await client.write(
        device,
        alarmAv,
        BacnetProperties.analogPresentValue,
        5,
        priority: 8,
      );
      final alarm = await received;
      expect(alarm.toState, BacnetEventState.lowLimit);
      expect(alarm.processId, 44);
      await client.acknowledgeEvent(alarm, source: 'integration test');
      final normal = alarms.notifications
          .firstWhere(
            (e) => e.object == alarmAv && e.toState == BacnetEventState.normal,
          )
          .timeout(const Duration(seconds: 10));
      await client.write(
        device,
        alarmAv,
        BacnetProperties.analogPresentValue,
        20,
        priority: 8,
      );
      await normal;
      expect(await alarms.refresh(), isFalse);
      await alarms.cancel();
      expect(await recipients(), isNot(contains(alarms.destination)));
    });
  });

  group('device management', () {
    const deviceObject = BacnetObject(
      type: BacnetObjectType.device,
      instance: device,
    );

    /// Waits for a server output line starting with [prefix] and
    /// containing [text].
    Future<String> serverLine(String prefix, String text) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        for (final line in server.lines) {
          if (line.startsWith(prefix) && line.contains(text)) return line;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      throw TimeoutException('no "$prefix ... $text" line from the server');
    }

    Matcher passwordFailure() => throwsA(
      isA<BacnetProtocolException>().having(
        (e) => e.errorCode,
        'code',
        BacnetErrorCode.passwordFailure,
      ),
    );

    test('requires the server password', () async {
      // bacnet-stack's default password is not accepted
      await expectLater(
        client.reinitializeDevice(
          device,
          BacnetReinitializedState.warmStart,
          password: 'filister',
        ),
        passwordFailure(),
      );
      await expectLater(
        client.deviceCommunicationControl(
          device,
          BacnetCommunicationState.disableInitiation,
          password: 'filister',
        ),
        passwordFailure(),
      );
      expect(server.lines.where((l) => l.startsWith('REINIT')), isEmpty);
      expect(server.lines.where((l) => l.startsWith('DCC')), isEmpty);
    });

    test('reports ReinitializeDevice requests', () async {
      await client.reinitializeDevice(
        device,
        BacnetReinitializedState.warmStart,
        password: 'demo-password',
      );
      await serverLine('REINIT', 'Warm Start');
    });

    test('reports DeviceCommunicationControl requests', () async {
      await client.deviceCommunicationControl(
        device,
        BacnetCommunicationState.disableInitiation,
        duration: const Duration(minutes: 5),
        password: 'demo-password',
      );
      await serverLine('DCC', 'Disable Initiation for 5 min');
      // the server still answers
      expect(
        await client.read(device, deviceObject, BacnetProperties.objectName),
        'DemoServer',
      );
      await client.deviceCommunicationControl(
        device,
        BacnetCommunicationState.enable,
        password: 'demo-password',
      );
      await serverLine('DCC', '(Enable)');
    });

    test('rejects services the server does not offer', () async {
      await expectLater(
        client.createObject(device, type: BacnetObjectType.analogValue),
        throwsA(isA<BacnetRejectException>()),
      );
      await expectLater(
        client.readFile(device, 99),
        throwsA(isA<BacnetProtocolException>()),
      );
    });
  });

  group('schedules', () {
    const schedule = BacnetObject(type: BacnetObjectType.schedule, instance: 1);
    const calendar = BacnetObject(type: BacnetObjectType.calendar, instance: 1);
    const target = BacnetObject(
      type: BacnetObjectType.analogValue,
      instance: 900,
    );

    test('name schedules (Who-Has, Object_Name)', () async {
      // bacnet-stack checked the uninitialized name it was about to fill
      // (tool/fuzz_native.dart checks that deterministically)
      final whoHas = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(whoHas.close);
      // Who-Has object name "Setpoint"
      const npdu = [
        0x01, 0x00, 0x10, 0x07, 0x3D, 0x09, 0x00, //
        0x53, 0x65, 0x74, 0x70, 0x6F, 0x69, 0x6E, 0x74,
      ];
      for (var i = 0; i < 20; i++) {
        whoHas.send(
          [0x81, 0x0A, 0x00, 4 + npdu.length, ...npdu],
          InternetAddress.loopbackIPv4,
          serverPort,
        );
      }
      for (var i = 0; i < 20; i++) {
        expect(
          await client.read(device, schedule, BacnetProperties.objectName),
          'Setpoint',
        );
      }
    });

    Future<void> expectTarget(double value) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (true) {
        final current = await client.read(
          device,
          target,
          BacnetProperties.analogPresentValue,
        );
        if (current == value) return;
        if (DateTime.now().isAfter(deadline)) {
          fail('AV 900 is $current, expected $value');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    List<List<BacnetTimeValue>> everyDay(double value) => [
      for (var day = 0; day < 7; day++)
        [
          BacnetTimeValue(
            const BacnetTime(hour: 0, minute: 0, second: 0, hundredths: 0),
            BacnetReal(value),
          ),
        ],
    ];

    test('writes its members at its priority', () async {
      await expectTarget(20);
      expect(
        await client.read(
          device,
          schedule,
          BacnetProperties.priorityForWriting,
        ),
        12,
      );
      expect(
        await client.read(
          device,
          schedule,
          BacnetProperties.schedulePresentValue,
        ),
        const BacnetReal(20),
      );
      // reported to the application as a write of the server itself
      expect(
        server.lines,
        contains(
          'WRITE PropertyWriteEvent(2:900 property 85 = BacnetReal(20.0) '
          '@ 12, internal)',
        ),
      );
    });

    test('clients change the weekly schedule', () async {
      await client.write(
        device,
        schedule,
        BacnetProperties.weeklySchedule,
        BacnetWeeklySchedule(everyDay(23.5)),
      );
      await expectTarget(23.5);
      expect(
        await client.read(device, schedule, BacnetProperties.weeklySchedule),
        BacnetWeeklySchedule(everyDay(23.5)),
      );
    });

    test('calendars select exceptions', () async {
      final now = DateTime.now();
      expect(
        await client.read(
          device,
          calendar,
          BacnetProperties.calendarPresentValue,
        ),
        isFalse,
      );
      await client.write(device, calendar, BacnetProperties.dateList, [
        BacnetCalendarDate(
          BacnetDate(year: now.year, month: now.month, day: now.day),
        ),
      ]);
      expect(
        await client.read(
          device,
          calendar,
          BacnetProperties.calendarPresentValue,
        ),
        isTrue,
      );
      await client.write(device, schedule, BacnetProperties.exceptionSchedule, [
        BacnetSpecialEvent(
          period: const BacnetCalendarReference(calendar),
          timeValues: [
            const BacnetTimeValue(
              BacnetTime(hour: 0, minute: 0, second: 0, hundredths: 0),
              BacnetReal(30),
            ),
          ],
          priority: 1,
        ),
      ]);
      await expectTarget(30);
      // without the date the weekly schedule applies again
      await client.write(
        device,
        calendar,
        BacnetProperties.dateList,
        const <BacnetCalendarEntry>[],
      );
      await expectTarget(23.5);
    });
  });

  group('trend logs', () {
    const polled = BacnetObject(type: BacnetObjectType.trendLog, instance: 1);
    const logged = BacnetObject(
      type: BacnetObjectType.analogValue,
      instance: 910,
    );

    Future<TrendLogData> waitForLog(
      int instance,
      bool Function(TrendLogData log) test,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (true) {
        final log = await client.getTrendLog(device, instance);
        if (test(log)) return log;
        if (DateTime.now().isAfter(deadline)) fail('trend log $instance: $log');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    test('polls a property of the server', () async {
      final log = await waitForLog(1, (log) => log.entries.length >= 2);
      expect(log.entries.first.value, const BacnetReal(1));
      expect(log.entries.first.statusFlags, const BacnetStatusFlags());
      await client.write(
        device,
        logged,
        BacnetProperties.analogPresentValue,
        42,
      );
      final changed = await waitForLog(
        1,
        (log) => log.entries.last.value == const BacnetReal(42),
      );
      expect(changed.totalRecords, greaterThanOrEqualTo(3));
      expect(
        await client.read(device, polled, BacnetProperties.logInterval),
        100,
      );
      expect(
        await client.read(device, polled, BacnetProperties.bufferSize),
        100,
      );
    });

    test('records the values of the application', () async {
      await client.write(
        device,
        const BacnetObject(type: BacnetObjectType.analogValue, instance: 911),
        BacnetProperties.analogPresentValue,
        7.5,
      );
      final log = await waitForLog(2, (log) => log.entries.isNotEmpty);
      expect(log.entries.last.value, const BacnetReal(7.5));
      expect(
        log.entries.last.statusFlags,
        const BacnetStatusFlags(overridden: true),
      );
    });

    test('answers ReadRange by position, sequence number and time', () async {
      await waitForLog(1, (log) => log.entries.length >= 3);
      final count = await client.read(
        device,
        polled,
        BacnetProperties.recordCount,
      );
      final total = await client.read(
        device,
        polled,
        BacnetProperties.totalRecordCount,
      );
      final first = await client.readRange(
        device,
        BacnetObjectType.trendLog,
        1,
        BacnetPropertyId.logBuffer,
        range: const BacnetRange.byPosition(1, 2),
      );
      expect(first.itemCount, 2);
      expect(first.resultFlags[0], isTrue); // first item
      final bySequence = await client.readRange(
        device,
        BacnetObjectType.trendLog,
        1,
        BacnetPropertyId.logBuffer,
        range: BacnetRange.bySequenceNumber(total - count + 1, 2),
      );
      expect(bySequence.itemCount, 2);
      expect(bySequence.firstSequenceNumber, total - count + 1);
      expect(bySequence.items, first.items);
      final recent = await client.readRange(
        device,
        BacnetObjectType.trendLog,
        1,
        BacnetPropertyId.logBuffer,
        range: BacnetRange.byTime(
          DateTime.now().subtract(const Duration(hours: 1)),
          1,
        ),
      );
      expect(recent.itemCount, 1);
      expect(recent.firstSequenceNumber, total - count + 1);
      final none = await client.readRange(
        device,
        BacnetObjectType.trendLog,
        1,
        BacnetPropertyId.logBuffer,
        range: BacnetRange.byTime(
          DateTime.now().add(const Duration(hours: 1)),
          5,
        ),
      );
      expect(none.itemCount, 0);
      await expectLater(
        client.readProperty(
          device,
          BacnetObjectType.trendLog,
          1,
          BacnetPropertyId.logBuffer,
        ),
        throwsA(
          isA<BacnetProtocolException>().having(
            (e) => e.errorCode,
            'code',
            BacnetErrorCode.readAccessDenied,
          ),
        ),
      );
    });

    test('clients disable, purge and resize the log', () async {
      await client.write(device, polled, BacnetProperties.enable, false);
      await client.write(device, polled, BacnetProperties.recordCount, 0);
      final purged = await client.getTrendLog(device, 1);
      expect(purged.entries, hasLength(1));
      expect(purged.entries.single.datum, isA<TrendLogStatus>());
      await client.write(device, polled, BacnetProperties.bufferSize, 50);
      expect(
        await client.read(device, polled, BacnetProperties.bufferSize),
        50,
      );
      expect(
        await client.read(device, polled, BacnetProperties.recordCount),
        0,
      );
      await client.write(device, polled, BacnetProperties.enable, true);
      await expectLater(
        client.write(device, polled, BacnetProperties.bufferSize, 60),
        throwsA(isA<BacnetProtocolException>()),
      );
      await waitForLog(1, (log) => log.entries.isNotEmpty);
    });
  });

  group('files', () {
    const notes = BacnetObject(type: BacnetObjectType.file, instance: 1);
    const firmware = BacnetObject(type: BacnetObjectType.file, instance: 2);

    test('remote clients cannot grow files without limit', () async {
      // 16 MiB by default
      await expectLater(
        client.writeFileStream(device, 1, const [1], start: 20000000),
        throwsA(isA<BacnetProtocolException>()),
      );
      await expectLater(
        client.writeProperty(
          device,
          BacnetObjectType.file,
          1,
          BacnetPropertyId.fileSize,
          const BacnetUnsigned(1 << 30),
        ),
        throwsA(isA<BacnetProtocolException>()),
      );
      expect(
        await client.read(device, notes, BacnetProperties.fileSize),
        lessThan(1 << 20),
      );
    });

    Future<String> fileLine(String text) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        for (final line in server.lines) {
          if (line.startsWith('FILE') && line.contains(text)) return line;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      throw TimeoutException('no "FILE ... $text" line from the server');
    }

    test('reads files of the server', () async {
      expect(
        String.fromCharCodes(await client.readFile(device, 1)),
        'hello from the server',
      );
      expect(
        await client.read(device, notes, BacnetProperties.fileType),
        'text/plain',
      );
      expect(
        await client.read(device, notes, BacnetProperties.description),
        'Notes of the operator',
      );
      final firmwareContent = await client.readFile(device, 2, chunkSize: 1000);
      expect(firmwareContent, List.generate(3000, (i) => i & 0xFF));
      expect(
        await client.read(device, firmware, BacnetProperties.readOnly),
        isTrue,
      );
      expect(
        await client.read(device, firmware, BacnetProperties.fileSize),
        3000,
      );
    });

    test('remote clients write, append and truncate', () async {
      final before = await client.read(
        device,
        notes,
        BacnetProperties.modificationDate,
      );
      await client.writeFile(device, 1, 'HELLO'.codeUnits);
      await fileLine('5 octets at 0');
      expect(
        String.fromCharCodes(await client.readFile(device, 1)),
        'HELLO from the server',
      );
      // an append answers with the position it wrote at
      expect(
        await client.writeFileStream(device, 1, '!'.codeUnits, start: -1),
        21,
      );
      await fileLine('1 octets at 21');
      await client.writeFile(device, 1, 'short'.codeUnits, truncate: true);
      expect(String.fromCharCodes(await client.readFile(device, 1)), 'short');
      final after = await client.read(
        device,
        notes,
        BacnetProperties.modificationDate,
      );
      expect(after, isNot(before));
      expect(
        await client.read(device, notes, BacnetProperties.archive),
        isFalse,
      );
    });

    test('the description is not the storage of the content', () async {
      await client.write(
        device,
        notes,
        BacnetProperties.description,
        'Changed by a client',
      );
      expect(
        await client.read(device, notes, BacnetProperties.description),
        'Changed by a client',
      );
      // the content is still there
      expect(
        await client.read(device, notes, BacnetProperties.fileSize),
        greaterThan(0),
      );
      await client.writeFileStream(device, 1, 'x'.codeUnits);
      expect((await client.readFile(device, 1)).first, 'x'.codeUnitAt(0));
    });

    test('read only files and record access are refused', () async {
      await expectLater(
        client.writeFileStream(device, 2, const [1, 2, 3]),
        throwsA(
          isA<BacnetProtocolException>().having(
            (e) => e.errorCode,
            'code',
            BacnetErrorCode.fileAccessDenied,
          ),
        ),
      );
      await expectLater(
        client.write(device, firmware, BacnetProperties.description, 'x'),
        throwsA(
          isA<BacnetProtocolException>().having(
            (e) => e.errorCode,
            'code',
            BacnetErrorCode.writeAccessDenied,
          ),
        ),
      );
      await expectLater(
        client.readFileRecords(device, 1, start: 0, count: 1),
        throwsA(
          isA<BacnetProtocolException>().having(
            (e) => e.errorCode,
            'code',
            BacnetErrorCode.invalidFileAccessMethod,
          ),
        ),
      );
      await expectLater(
        client.readFileStream(device, 2, start: 5000, count: 10),
        throwsA(
          isA<BacnetProtocolException>().having(
            (e) => e.errorCode,
            'code',
            BacnetErrorCode.invalidFileStartPosition,
          ),
        ),
      );
    });
  });

  group('backup and restore', () {
    const deviceObject = BacnetObject(
      type: BacnetObjectType.device,
      instance: device,
    );

    test('backs up the configuration files', () async {
      final progress = <int>[];
      final backup = await client.backupDevice(
        device,
        password: 'demo-password',
        onProgress: (done, total) => progress.add(done),
      );
      expect(backup.deviceId, device);
      expect(backup.files, [
        BacnetBackupFile.stream(
          instance: 3,
          data: 'setpoint=21'.codeUnits,
          fileType: 'text/plain',
        ),
      ]);
      expect(progress, [0, 1]);
      expect(
        await client.read(
          device,
          deviceObject,
          BacnetProperties.backupAndRestoreState,
        ),
        BacnetBackupState.idle,
      );
      final json = jsonDecode(jsonEncode(backup.toJson()));
      expect(BacnetDeviceBackup.fromJson(json as Map<String, Object?>), backup);
    });

    test('restores and the application applies the files', () async {
      final backup = await client.backupDevice(
        device,
        password: 'demo-password',
      );
      // the configuration changes after the backup
      await client.writeFile(device, 3, 'setpoint=99'.codeUnits);
      await client.restoreDevice(device, backup, password: 'demo-password');
      expect(server.lines, contains('RESTORED setpoint=21'));
      expect(
        String.fromCharCodes(await client.readFile(device, 3)),
        'setpoint=21',
      );
      final restored = await client.read(
        device,
        deviceObject,
        BacnetProperties.lastRestoreTime,
      );
      expect(restored, isA<BacnetTimeStampDateTime>());
    });

    test('refuses wrong passwords and concurrent procedures', () async {
      await expectLater(
        client.backupDevice(device, password: 'wrong'),
        throwsA(
          isA<BacnetProtocolException>().having(
            (e) => e.errorCode,
            'code',
            BacnetErrorCode.passwordFailure,
          ),
        ),
      );
      await client.reinitializeDevice(
        device,
        BacnetReinitializedState.startRestore,
        password: 'demo-password',
      );
      expect(
        await client.read(
          device,
          deviceObject,
          BacnetProperties.backupAndRestoreState,
        ),
        BacnetBackupState.performingARestore,
      );
      await expectLater(
        client.reinitializeDevice(
          device,
          BacnetReinitializedState.startBackup,
          password: 'demo-password',
        ),
        throwsA(
          isA<BacnetProtocolException>().having(
            (e) => e.errorCode,
            'code',
            BacnetErrorCode.configurationInProgress,
          ),
        ),
      );
      await client.reinitializeDevice(
        device,
        BacnetReinitializedState.abortRestore,
        password: 'demo-password',
      );
      expect(
        await client.read(
          device,
          deviceObject,
          BacnetProperties.backupAndRestoreState,
        ),
        BacnetBackupState.idle,
      );
      expect(
        await client.read(
          device,
          deviceObject,
          BacnetProperties.configurationFiles,
        ),
        [const BacnetObject(type: BacnetObjectType.file, instance: 3)],
      );
    });
  });

  group('network layer', () {
    const clientPort = 47862;
    late FakeRouter router;

    setUp(() async {
      router = await FakeRouter.bind(networks: [5, 6], networkNumber: 3);
    });
    tearDown(() => router.close());

    test('receives router announcements', () async {
      final announcement = client.networkMessages.firstWhere(
        (event) => event.port == router.port,
      );
      router.send(clientPort, 0x01, [0, 5, 0, 6]);
      final event = await announcement.timeout(const Duration(seconds: 5));
      expect(event.message, BacnetIAmRouterToNetwork([5, 6]));
      expect(event.ipAddress, '127.0.0.1');
      expect(event.net, 0);
      expect(event.destinationNetwork, 0);
    });

    test('reads the routing table of a router', () async {
      final table = await client.readRoutingTable(
        '127.0.0.1',
        port: router.port,
      );
      expect(table, [
        BacnetRoutingTableEntry(network: 5, portId: 1),
        BacnetRoutingTableEntry(network: 6, portId: 2),
      ]);
      final query = router.received.single;
      expect(query.type, 0x06);
      expect(query.bvlcFunction, 0x0A); // Original-Unicast-NPDU
      expect(query.expectingReply, isTrue);
      expect(query.data, [0]);
    });

    test('routing table queries time out without an answer', () async {
      final silent = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(silent.close);
      await expectLater(
        client.readRoutingTable(
          '127.0.0.1',
          port: silent.port,
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<BacnetTimeoutException>()),
      );
    });

    test('sends network messages to a router', () async {
      final answer = client.networkMessages.firstWhere(
        (event) => event.port == router.port,
      );
      await client.sendNetworkMessage(
        BacnetWhoIsRouterToNetwork(network: 6),
        ip: '127.0.0.1',
        port: router.port,
      );
      expect(
        (await answer.timeout(const Duration(seconds: 5))).message,
        BacnetIAmRouterToNetwork([6]),
      );
      expect(router.received.single.data, [0, 6]);
      expect(router.received.single.destinationNetwork, isNull);

      // a proprietary message for a device on network 9
      await client.sendNetworkMessage(
        BacnetOtherNetworkMessage(const BacnetNetworkMessageType(0x80), const [
          1,
          2,
        ], vendorId: 260),
        ip: '127.0.0.1',
        port: router.port,
        network: 9,
        adr: const [7],
      );
      await _waitFor(() => router.received.length == 2);
      final proprietary = router.received.last;
      expect(proprietary.type, 0x80);
      expect(proprietary.destinationNetwork, 9);
      expect(proprietary.data, [1, 2]);
      expect(
        () => client.sendNetworkMessage(
          const BacnetWhatIsNetworkNumber(),
          adr: const [1],
        ),
        throwsArgumentError,
      );
    });

    test('broadcasts find routers and the network number', () async {
      if (!await router.listenForBroadcasts(clientPort)) {
        markTestSkipped('no broadcasts on the loopback interface');
        return;
      }
      final routers = await client.discoverRouters(
        timeout: const Duration(seconds: 1),
      );
      expect(
        routers,
        contains(
          BacnetRouter(
            mac: [127, 0, 0, 1, router.port >> 8, router.port & 0xFF],
            networks: const [5, 6],
          ),
        ),
      );
      final whoIs = router.received.firstWhere((m) => m.type == 0x00);
      expect(whoIs.bvlcFunction, 0x0B); // Original-Broadcast-NPDU
      expect(whoIs.destinationNetwork, isNull); // local broadcast
      expect(
        await client.whatIsNetworkNumber(timeout: const Duration(seconds: 2)),
        BacnetNetworkNumberIs(network: 3, configured: true),
      );
    });
  });

  group('provisioning and channels', () {
    Future<String> serverLine(String prefix, String text) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        for (final line in server.lines) {
          if (line.startsWith(prefix) && line.contains(text)) return line;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      throw TimeoutException('no "$prefix ... $text" line from the server');
    }

    test('describes the channel', () async {
      const channel = BacnetObject(type: BacnetObjectType.channel, instance: 1);
      expect(
        await client.read(device, channel, BacnetProperties.channelNumber),
        7,
      );
      expect(
        (await client.read(
          device,
          channel,
          BacnetProperties.controlGroups,
        )).first,
        5,
      );
      final members = BacnetDeviceObjectPropertyReference.listFromValue(
        await client.readProperty(
          device,
          BacnetObjectType.channel,
          1,
          BacnetPropertyId.listOfObjectPropertyReferences,
          arrayIndex: 1,
        ),
      );
      expect(members, [
        const BacnetDeviceObjectPropertyReference(
          object: BacnetObject(
            type: BacnetObjectType.analogValue,
            instance: 920,
          ),
          property: BacnetPropertyId.presentValue,
          device: BacnetObject(type: BacnetObjectType.device, instance: device),
        ),
      ]);
    });

    test('WriteGroup writes the members of the channels', () async {
      await client.writeGroup(
        5,
        [
          BacnetGroupChannelValue(7, const BacnetReal(42.5)),
          // no channel 8 in the device
          BacnetGroupChannelValue(8, const BacnetBoolean(true)),
        ],
        writePriority: 10,
        deviceId: device,
      );
      expect(
        await serverLine('GROUP', 'group 5 @ 10'),
        contains('channel 7 = BacnetReal(42.5)'),
      );
      expect(
        await serverLine('WRITE', '2:920'),
        'WRITE PropertyWriteEvent(2:920 property 85 = BacnetReal(42.5) @ 10, '
        'internal)',
      );
      expect(
        await client.readProperty(
          device,
          BacnetObjectType.analogValue,
          920,
          BacnetPropertyId.presentValue,
        ),
        const BacnetReal(42.5),
      );
      const channel = BacnetObject(type: BacnetObjectType.channel, instance: 1);
      expect(
        await client.readProperty(
          device,
          channel.type,
          channel.instance,
          BacnetPropertyId.lastPriority,
        ),
        const BacnetUnsigned(10),
      );
      // other groups leave the channel alone
      await client.writeGroup(6, [
        BacnetGroupChannelValue(7, const BacnetReal(1)),
      ], deviceId: device);
      await client.writeGroup(5, [
        BacnetGroupChannelValue(7, const BacnetReal(2), overridingPriority: 9),
      ], deviceId: device);
      await serverLine('GROUP', 'group 5 @ 16');
      await _waitFor(
        () => server.lines.any((l) => l.contains('2:920') && l.contains('@ 9')),
      );
      expect(
        server.lines.where(
          (l) => l.startsWith('WRITE') && l.contains('BacnetReal(1.0)'),
        ),
        isEmpty,
      );
    });

    test('assigns the device instance with Who-Am-I / You-Are', () async {
      const assigned = device + 100;
      Future<void> provision(int instance) async {
        final request = client.whoAmIRequests.first.timeout(
          const Duration(seconds: 10),
        );
        server.send('provision 127.0.0.1 47862');
        final whoAmI = await request;
        expect(whoAmI.modelName, 'Demo');
        expect(whoAmI.serialNumber, 'DEMO-$device');
        expect(whoAmI.source.port, serverPort);
        await client.sendYouAre(
          vendorId: whoAmI.vendorId,
          modelName: whoAmI.modelName,
          serialNumber: whoAmI.serialNumber,
          deviceId: instance,
          destination: whoAmI.source,
        );
        await serverLine('PROVISIONED', '$instance');
      }

      await provision(assigned);
      addTearDown(() async {
        server.lines.removeWhere((l) => l.startsWith('PROVISIONED'));
        await provision(device);
      });
      await client.addDeviceBinding(assigned, '127.0.0.1', port: serverPort);
      expect(
        await client.read(
          assigned,
          const BacnetObject(type: BacnetObjectType.device, instance: assigned),
          BacnetProperties.serialNumber,
        ),
        'DEMO-$device',
      );
      // You-Are of other devices are ignored
      server.lines.removeWhere((l) => l.startsWith('PROVISIONED'));
      final request = client.whoAmIRequests.first.timeout(
        const Duration(seconds: 10),
      );
      server.send('provision 127.0.0.1 47862');
      final whoAmI = await request;
      await client.sendYouAre(
        vendorId: whoAmI.vendorId,
        modelName: whoAmI.modelName,
        serialNumber: 'OTHER',
        deviceId: 1,
        destination: whoAmI.source,
      );
      await client.sendYouAre(
        vendorId: whoAmI.vendorId,
        modelName: whoAmI.modelName,
        serialNumber: whoAmI.serialNumber,
        deviceId: assigned,
        destination: whoAmI.source,
      );
      await serverLine('PROVISIONED', '$assigned');
    });
  });

  group('COV of several properties', () {
    const sensor = BacnetObject(
      type: BacnetObjectType.analogInput,
      instance: 1,
    );
    const fan = BacnetObject(type: BacnetObjectType.binaryValue, instance: 2);
    final specifications = [
      BacnetCovSubscriptionSpecification(sensor, const [
        BacnetCovReference(BacnetPropertyId.presentValue, covIncrement: 0.5),
        BacnetCovReference(BacnetPropertyId.statusFlags),
      ]),
      BacnetCovSubscriptionSpecification(fan, const [
        BacnetCovReference(BacnetPropertyId.presentValue, timestamped: true),
      ]),
    ];
    var nextDevice = 7300;

    Future<CovMultipleDevice> covDevice({
      Set<BacnetPropertyId> refused = const {},
    }) async {
      final device = await CovMultipleDevice.bind(
        deviceId: nextDevice++,
        refused: refused,
      );
      addTearDown(device.close);
      await client.addDeviceBinding(
        device.deviceId,
        '127.0.0.1',
        port: device.port,
      );
      return device;
    }

    test('subscribes and receives the notifications', () async {
      final device = await covDevice();
      await client.subscribeCOVPropertyMultiple(
        device.deviceId,
        specifications,
        processId: 9,
        confirmed: true,
        lifetime: const Duration(minutes: 10),
        maxNotificationDelay: const Duration(seconds: 2),
      );
      final request = device.subscriptions.single;
      expect(request.subscriberProcessId, 9);
      expect(request.confirmed, isTrue);
      expect(request.lifetime, 600);
      expect(request.maxNotificationDelay, 2);
      expect(request.specifications, specifications);

      final events = client.covEvents
          .where((e) => e.deviceId == device.deviceId)
          .take(2)
          .toList();
      const changed = BacnetTime(hour: 8, minute: 15, second: 0, hundredths: 0);
      final sent = BacnetDateTime.fromDateTime(DateTime(2026, 10, 1, 8, 15, 1));
      final invokeId = device.notify(
        [
          (
            object: sensor,
            values: const [
              CovPropertyValue(
                propertyId: BacnetPropertyId.presentValue,
                value: BacnetReal(21.5),
              ),
              CovPropertyValue(
                propertyId: BacnetPropertyId.statusFlags,
                value: BacnetBitString([false, false, false, false]),
              ),
            ],
            changeTimes: const {},
          ),
          (
            object: fan,
            values: const [
              CovPropertyValue(
                propertyId: BacnetPropertyId.presentValue,
                value: BacnetEnumerated(1),
              ),
            ],
            changeTimes: const {BacnetPropertyId.presentValue: changed},
          ),
        ],
        confirmed: true,
        timeRemaining: 590,
        timestamp: sent,
      );
      final [ai, bv] = await events.timeout(const Duration(seconds: 5));
      expect(ai.object, sensor);
      expect(ai.presentValue, const BacnetReal(21.5));
      expect(ai.statusFlags, const BacnetStatusFlags());
      expect(ai.subscriberProcessId, 9);
      expect(ai.timeRemaining, 590);
      expect(ai.confirmed, isTrue);
      expect(ai.notificationTime, sent);
      expect(bv.object, fan);
      expect(bv.presentValue, const BacnetEnumerated(1));
      expect(bv.changeTimes, {BacnetPropertyId.presentValue: changed});
      // the client acknowledged the confirmed notification
      await _waitFor(() => device.acknowledged.contains(invokeId));

      final unconfirmed = client.covEvents.firstWhere(
        (e) => e.deviceId == device.deviceId,
      );
      device.notify([
        (
          object: sensor,
          values: const [
            CovPropertyValue(
              propertyId: BacnetPropertyId.presentValue,
              value: BacnetReal(22),
            ),
          ],
          changeTimes: const {},
        ),
      ], confirmed: false);
      final event = await unconfirmed.timeout(const Duration(seconds: 5));
      expect(event.presentValue, const BacnetReal(22));
      expect(event.confirmed, isFalse);
      expect(event.notificationTime, isNull);

      await client.unsubscribeCOVPropertyMultiple(
        device.deviceId,
        specifications,
        processId: 9,
      );
      expect(device.subscriptions.last.lifetime, isNull);
      expect(device.subscriptions.last.confirmed, isNull);
    });

    test('names the subscription the device refuses', () async {
      final device = await covDevice(refused: {BacnetPropertyId.statusFlags});
      await expectLater(
        client.subscribeCOVPropertyMultiple(device.deviceId, specifications),
        throwsA(
          isA<BacnetProtocolException>()
              .having((e) => e.errorClass, 'class', BacnetErrorClass.services)
              .having(
                (e) => e.firstFailedSubscription,
                'first failed subscription',
                const BacnetFailedCovSubscription(
                  object: sensor,
                  property: BacnetPropertyId.statusFlags,
                  errorClass: BacnetErrorClass.property,
                  errorCode: BacnetErrorCode.unknownProperty,
                ),
              ),
        ),
      );
    });

    test('devices without the service reject it', () async {
      await expectLater(
        client.subscribeCOVPropertyMultiple(device, specifications),
        throwsA(isA<BacnetRejectException>()),
      );
    });
  });
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
