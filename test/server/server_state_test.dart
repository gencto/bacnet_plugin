import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

void main() {
  const state = BacnetServerState(
    deviceInstance: 1234,
    objects: [
      BacnetObjectState(
        type: BacnetObjectType.analogValue,
        instance: 1,
        name: 'Setpoint',
        description: 'Zone setpoint',
        presentValue: BacnetReal(21.5),
      ),
      BacnetObjectState(
        type: BacnetObjectType.notificationClass,
        instance: 1,
        name: 'Alarms',
      ),
    ],
  );

  group('BacnetServerState JSON', () {
    test('round-trips through toJson/fromJson', () {
      final restored = BacnetServerState.fromJson(state.toJson());
      expect(restored.deviceInstance, 1234);
      expect(restored.objects, hasLength(2));
      final setpoint = restored.objects.first;
      expect(setpoint.type, BacnetObjectType.analogValue);
      expect(setpoint.instance, 1);
      expect(setpoint.name, 'Setpoint');
      expect(setpoint.description, 'Zone setpoint');
      expect(setpoint.presentValue, const BacnetReal(21.5));
      final nc = restored.objects.last;
      expect(nc.type, BacnetObjectType.notificationClass);
      expect(nc.name, 'Alarms');
      expect(nc.presentValue, isNull);
      expect(nc.description, isNull);
    });

    test('rejects malformed JSON', () {
      expect(
        () => BacnetServerState.fromJson(const {'version': 1}),
        throwsFormatException,
      );
      expect(
        () => BacnetObjectState.fromJson(const {'instance': 1}),
        throwsFormatException,
      );
    });
  });

  group('JsonFileServerStateStore', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('bacnet_state'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('saves and loads a snapshot', () async {
      final store = JsonFileServerStateStore(File('${dir.path}/state.json'));
      expect(await store.load(), isNull);
      await store.save(state);
      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.objects, hasLength(2));
      expect(loaded.deviceInstance, 1234);
      expect(loaded.objects.first.presentValue, const BacnetReal(21.5));
    });

    test(
      'creates missing parent directories and replaces atomically',
      () async {
        final store = JsonFileServerStateStore(
          File('${dir.path}/nested/dir/state.json'),
        );
        await store.save(state);
        await store.save(
          const BacnetServerState(objects: [], deviceInstance: 7),
        );
        final loaded = await store.load();
        expect(loaded!.objects, isEmpty);
        expect(loaded.deviceInstance, 7);
        // no leftover temporary file
        expect(
          Directory('${dir.path}/nested/dir').listSync().map((e) => e.path),
          [endsWith('state.json')],
        );
      },
    );
  });
}
