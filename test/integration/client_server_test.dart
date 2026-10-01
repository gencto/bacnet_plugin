@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

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
    expect(objects, hasLength(104));
    expect(
      await client.read(device, deviceObject, BacnetProperties.vendorName),
      'bacnet_plugin',
    );
  });

  test('scans the object list', () async {
    final objects = await client.scanDevice(device);
    // device, network port, 100 AV, BV, MSV
    expect(objects, hasLength(104));
    final scanner = DeviceScanner(client);
    final details = await scanner.getDeviceDetails(device);
    expect(details.deviceName, 'DemoServer');
    expect(details.vendorName, 'bacnet_plugin');
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
}
