import 'dart:convert';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

void main() {
  group('BacnetDeviceBackup', () {
    final backup = BacnetDeviceBackup(
      deviceId: 1234,
      time: DateTime.utc(2026, 10, 1, 12),
      files: [
        BacnetBackupFile.stream(
          instance: 1,
          data: const [0, 1, 2, 255],
          fileType: 'application/octet-stream',
        ),
        BacnetBackupFile.records(
          instance: 2,
          records: ['first'.codeUnits, const <int>[], 'third'.codeUnits],
        ),
      ],
    );

    test('round trips through JSON', () {
      final json = jsonDecode(jsonEncode(backup.toJson()));
      expect(BacnetDeviceBackup.fromJson(json as Map<String, Object?>), backup);
      expect(backup.files[0].accessMethod, BacnetFileAccessMethod.streamAccess);
      expect(backup.files[1].accessMethod, BacnetFileAccessMethod.recordAccess);
      expect(backup.files[1].size, 10);
      expect(
        backup.files[1].object,
        const BacnetObject(type: BacnetObjectType.file, instance: 2),
      );
      expect(backup.toString(), contains('2 files'));
    });

    test('rejects malformed JSON', () {
      for (final json in <Map<String, Object?>>[
        {},
        {'deviceId': 1, 'time': '2026-01-01', 'files': 'x'},
        {
          'deviceId': 1,
          'time': '2026-01-01',
          'files': [
            {'instance': 1},
          ],
        },
        {
          'deviceId': 1,
          'time': '2026-01-01',
          'files': [
            {
              'instance': 1,
              'records': [1],
            },
          ],
        },
      ]) {
        expect(
          () => BacnetDeviceBackup.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
    });
  });
}
