import 'dart:async';
import 'dart:typed_data';

import '../client/bacnet_client.dart';
import '../constants/enumerations.dart';
import '../constants/errors.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import '../models/backup.dart';
import '../models/bacnet_property.dart';
import '../models/bacnet_value.dart';
import '../models/files.dart';
import 'file_transfer.dart';

/// Backup and restore of devices (ASHRAE 135 clause 19.1): the content of
/// their configuration files, read and written with ReinitializeDevice
/// START_BACKUP/END_BACKUP and START_RESTORE/END_RESTORE around the file
/// transfers.
///
/// ```dart
/// final backup = await client.backupDevice(1234, password: 'secret');
/// // ... replace the controller ...
/// await client.restoreDevice(1234, backup, password: 'secret');
/// ```
extension BacnetDeviceBackups on BacnetClient {
  /// Backs up [deviceId]: starts the backup, waits until the device is
  /// ready (Backup_And_Restore_State, at most [preparationTimeout]), reads
  /// the files of Configuration_Files and ends the backup (also when it
  /// fails). [onProgress] reports the files read.
  Future<BacnetDeviceBackup> backupDevice(
    int deviceId, {
    String? password,
    Duration preparationTimeout = const Duration(minutes: 2),
    BacnetFileProgress? onProgress,
    Duration? timeout,
  }) async {
    final time = DateTime.now();
    await reinitializeDevice(
      deviceId,
      BacnetReinitializedState.startBackup,
      password: password,
      timeout: timeout,
    );
    try {
      await _awaitBackupState(
        deviceId,
        BacnetBackupState.performingABackup,
        preparationTimeout,
        BacnetProperties.backupPreparationTime,
      );
      final objects = await read(
        deviceId,
        _device(deviceId),
        BacnetProperties.configurationFiles,
        timeout: timeout,
      );
      final files = <BacnetBackupFile>[];
      onProgress?.call(0, objects.length);
      for (final object in objects) {
        files.add(await _readFile(deviceId, object, timeout));
        onProgress?.call(files.length, objects.length);
      }
      await reinitializeDevice(
        deviceId,
        BacnetReinitializedState.endBackup,
        password: password,
        timeout: timeout,
      );
      return BacnetDeviceBackup(deviceId: deviceId, time: time, files: files);
    } on Object {
      await _quietly(
        reinitializeDevice(
          deviceId,
          BacnetReinitializedState.endBackup,
          password: password,
          timeout: timeout,
        ),
      );
      rethrow;
    }
  }

  /// Restores [backup] to [deviceId]: starts the restore, waits until the
  /// device is ready, writes the files (and their size where the device
  /// allows it) and ends the restore; aborts it when a step fails. Waits up
  /// to [completionTimeout] for the device to apply the files and throws a
  /// [BacnetException] when it reports a restore failure.
  ///
  /// [backup] may come from another device of the same kind (a replaced
  /// controller): the files are written to the same instances.
  Future<void> restoreDevice(
    int deviceId,
    BacnetDeviceBackup backup, {
    String? password,
    Duration preparationTimeout = const Duration(minutes: 2),
    Duration completionTimeout = const Duration(minutes: 2),
    BacnetFileProgress? onProgress,
    Duration? timeout,
  }) async {
    await reinitializeDevice(
      deviceId,
      BacnetReinitializedState.startRestore,
      password: password,
      timeout: timeout,
    );
    try {
      await _awaitBackupState(
        deviceId,
        BacnetBackupState.performingARestore,
        preparationTimeout,
        BacnetProperties.restorePreparationTime,
      );
      onProgress?.call(0, backup.files.length);
      var done = 0;
      for (final file in backup.files) {
        await _writeFile(deviceId, file, timeout);
        onProgress?.call(++done, backup.files.length);
      }
      await reinitializeDevice(
        deviceId,
        BacnetReinitializedState.endRestore,
        password: password,
        timeout: timeout,
      );
    } on Object {
      await _quietly(
        reinitializeDevice(
          deviceId,
          BacnetReinitializedState.abortRestore,
          password: password,
          timeout: timeout,
        ),
      );
      rethrow;
    }
    await _awaitBackupState(
      deviceId,
      BacnetBackupState.idle,
      completionTimeout,
      BacnetProperties.restoreCompletionTime,
    );
  }

  static BacnetObject _device(int deviceId) =>
      BacnetObject(type: BacnetObjectType.device, instance: deviceId);

  /// Waits until Backup_And_Restore_State is [wanted]; devices without the
  /// property get the time of [preparation] instead. Devices may not answer
  /// while they prepare.
  Future<void> _awaitBackupState(
    int deviceId,
    BacnetBackupState wanted,
    Duration timeout,
    BacnetProperty<int> preparation,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        final state = await read(
          deviceId,
          _device(deviceId),
          BacnetProperties.backupAndRestoreState,
        );
        if (state == wanted) return;
        if (state == BacnetBackupState.backupFailure ||
            state == BacnetBackupState.restoreFailure) {
          throw BacnetException('device $deviceId reports ${state.label}');
        }
      } on BacnetProtocolException catch (e) {
        if (e.errorCode != BacnetErrorCode.unknownProperty) rethrow;
        final seconds = await read(
          deviceId,
          _device(deviceId),
          preparation,
        ).then<int?>((value) => value, onError: (Object _) => null);
        if (seconds != null && seconds > 0) {
          await Future<void>.delayed(Duration(seconds: seconds));
        }
        return;
      } on BacnetTimeoutException {
        // the device may not answer while it prepares
      }
      if (DateTime.now().isAfter(deadline)) {
        throw BacnetTimeoutException(
          'device $deviceId did not reach ${wanted.label}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<BacnetBackupFile> _readFile(
    int deviceId,
    BacnetObject object,
    Duration? timeout,
  ) async {
    final method = await read(
      deviceId,
      object,
      BacnetProperties.fileAccessMethod,
      timeout: timeout,
    ).then<BacnetFileAccessMethod?>((m) => m, onError: (Object _) => null);
    final fileType = await read(
      deviceId,
      object,
      BacnetProperties.fileType,
      timeout: timeout,
    ).then<String?>((t) => t, onError: (Object _) => null);
    if (method == BacnetFileAccessMethod.recordAccess) {
      final records = <Uint8List>[];
      while (true) {
        final chunk = await readFileRecords(
          deviceId,
          object.instance,
          start: records.length,
          count: 16,
          timeout: timeout,
        );
        records.addAll(chunk.records);
        if (chunk.endOfFile || chunk.records.isEmpty) break;
      }
      return BacnetBackupFile.records(
        instance: object.instance,
        records: records,
        fileType: fileType,
      );
    }
    return BacnetBackupFile.stream(
      instance: object.instance,
      data: await readFile(deviceId, object.instance, timeout: timeout),
      fileType: fileType,
    );
  }

  Future<void> _writeFile(
    int deviceId,
    BacnetBackupFile file,
    Duration? timeout,
  ) async {
    if (file.data case final data?) {
      await writeFile(deviceId, file.instance, data, timeout: timeout);
      // the restored content may be shorter than the old one
      await _quietly(
        writeProperty(
          deviceId,
          BacnetObjectType.file,
          file.instance,
          BacnetPropertyId.fileSize,
          BacnetUnsigned(data.length),
          timeout: timeout,
        ),
      );
      return;
    }
    final records = file.records!;
    final limit = (await deviceMaxApdu(deviceId) ?? 480) - 32;
    var start = 0;
    while (start < records.length) {
      var end = start + 1;
      var size = records[start].length + 4;
      while (end < records.length && size + records[end].length + 4 <= limit) {
        size += records[end].length + 4;
        end++;
      }
      await writeFileRecords(
        deviceId,
        file.instance,
        records.sublist(start, end),
        start: start,
        timeout: timeout,
      );
      start = end;
    }
    await _quietly(
      writeProperty(
        deviceId,
        BacnetObjectType.file,
        file.instance,
        BacnetPropertyId.recordCount,
        BacnetUnsigned(records.length),
        timeout: timeout,
      ),
    );
  }

  static Future<void> _quietly(Future<void> request) =>
      request.then<void>((_) {}, onError: (Object _) {});
}
