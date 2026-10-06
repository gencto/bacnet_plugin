@Tags(['integration'])
library;

import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

/// Server-only (no client): one BacnetSystem per process, so this runs the
/// server in-process and verifies state persistence against the native engine.
void main() {
  late BacnetServer server;
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('bacnet_persist');
    server = BacnetServer(
      config: const BacnetConfig(
        interface: 'lo',
        port: 47899,
        logLevel: BacnetLogLevel.warning,
      ),
    );
    await server.start();
    await server.init(4194301, 'PersistTest');
  });

  tearDown(() async {
    await server.close();
    dir.deleteSync(recursive: true);
  });

  test('captures, saves and restores objects and present values', () async {
    await server.addObject(
      BacnetObjectType.analogValue,
      1,
      name: 'Setpoint',
      description: 'Zone setpoint',
      presentValue: const BacnetReal(21.5),
    );
    await server.addObject(
      BacnetObjectType.binaryValue,
      2,
      name: 'Switch',
      presentValue: const BacnetEnumerated(1),
    );
    await server.addNotificationClass(3, name: 'Alarms');

    final store = JsonFileServerStateStore(File('${dir.path}/state.json'));
    await server.saveState(store);

    final snapshot = await store.load();
    expect(snapshot, isNotNull);
    expect(snapshot!.deviceInstance, 4194301);
    expect(snapshot.objects, hasLength(3));
    expect(
      snapshot.objects
          .firstWhere((o) => o.type == BacnetObjectType.analogValue)
          .presentValue,
      const BacnetReal(21.5),
    );

    // remove the objects, then restore them from the store
    await server.removeObject(BacnetObjectType.analogValue, 1);
    await server.removeObject(BacnetObjectType.binaryValue, 2);
    await server.removeObject(BacnetObjectType.notificationClass, 3);

    expect(await server.restoreState(store), isTrue);

    const setpoint = BacnetObject(
      type: BacnetObjectType.analogValue,
      instance: 1,
    );
    expect(
      await server.read(setpoint, BacnetProperties.objectName),
      'Setpoint',
    );
    expect(
      await server.read(setpoint, BacnetProperties.analogPresentValue),
      closeTo(21.5, 0.001),
    );
    expect(
      await server.read(
        const BacnetObject(type: BacnetObjectType.binaryValue, instance: 2),
        BacnetProperties.objectName,
      ),
      'Switch',
    );
    expect(
      await server.read(
        const BacnetObject(
          type: BacnetObjectType.notificationClass,
          instance: 3,
        ),
        BacnetProperties.objectName,
      ),
      'Alarms',
    );
  });

  test('restoreState returns false when the store is empty', () async {
    final store = JsonFileServerStateStore(File('${dir.path}/missing.json'));
    expect(await server.restoreState(store), isFalse);
  });
}
