/// @docImport '../utilities/device_backup.dart';
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../constants/enumerations.dart';
import '../constants/object_types.dart';
import 'bacnet_value.dart';
import 'construct_support.dart';

/// A backup of a device (ASHRAE 135 clause 19.1): the content of its
/// configuration files, made by [BacnetDeviceBackups.backupDevice] and
/// written back by [BacnetDeviceBackups.restoreDevice].
///
/// [toJson] and [BacnetDeviceBackup.fromJson] store it:
///
/// ```dart
/// final backup = await client.backupDevice(1234, password: 'secret');
/// await File('ahu-1.json').writeAsString(jsonEncode(backup.toJson()));
/// ```
@immutable
final class BacnetDeviceBackup {
  /// Creates a backup.
  BacnetDeviceBackup({
    required this.deviceId,
    required this.time,
    required List<BacnetBackupFile> files,
  }) : files = List.unmodifiable(files);

  /// Reads a backup stored with [toJson].
  factory BacnetDeviceBackup.fromJson(Map<String, Object?> json) {
    final deviceId = json['deviceId'];
    final time = json['time'];
    final files = json['files'];
    if (deviceId is! int || time is! String || files is! List) {
      throw const FormatException('not a BACnet device backup');
    }
    return BacnetDeviceBackup(
      deviceId: deviceId,
      time: DateTime.parse(time),
      files: [
        for (final file in files)
          if (file is Map<String, Object?>)
            BacnetBackupFile.fromJson(file)
          else
            throw const FormatException('malformed backup file'),
      ],
    );
  }

  /// The device.
  final int deviceId;

  /// When the backup was made.
  final DateTime time;

  /// The configuration files, in the order of Configuration_Files.
  final List<BacnetBackupFile> files;

  /// The backup as JSON (file contents in base64).
  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'time': time.toIso8601String(),
    'files': [for (final file in files) file.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetDeviceBackup &&
      other.deviceId == deviceId &&
      other.time == time &&
      listEquals(other.files, files);

  @override
  int get hashCode => Object.hash(deviceId, time, Object.hashAll(files));

  @override
  String toString() =>
      'BacnetDeviceBackup(device $deviceId, ${files.length} files, $time)';
}

/// A configuration file of a [BacnetDeviceBackup]: the content of a File
/// object, as octets ([data], stream access) or records ([records]).
@immutable
final class BacnetBackupFile {
  /// A file with stream access.
  BacnetBackupFile.stream({
    required this.instance,
    required List<int> data,
    this.fileType,
  }) : data = Uint8List.fromList(data),
       records = null;

  /// A file with record access.
  BacnetBackupFile.records({
    required this.instance,
    required List<List<int>> records,
    this.fileType,
  }) : data = null,
       records = List.unmodifiable(records.map(Uint8List.fromList));

  /// Reads a file stored with [toJson].
  factory BacnetBackupFile.fromJson(Map<String, Object?> json) {
    final instance = json['instance'];
    final fileType = json['fileType'];
    if (instance is! int || (fileType != null && fileType is! String)) {
      throw const FormatException('malformed backup file');
    }
    return switch ((json['data'], json['records'])) {
      (final String data, null) => BacnetBackupFile.stream(
        instance: instance,
        data: base64Decode(data),
        fileType: fileType as String?,
      ),
      (null, final List<Object?> records) => BacnetBackupFile.records(
        instance: instance,
        records: [
          for (final record in records)
            if (record is String)
              base64Decode(record)
            else
              throw const FormatException('malformed backup record'),
        ],
        fileType: fileType as String?,
      ),
      _ => throw const FormatException('malformed backup file'),
    };
  }

  /// Instance of the File object.
  final int instance;

  /// The octets of a stream access file, null for record access.
  final Uint8List? data;

  /// The records of a record access file, null for stream access.
  final List<Uint8List>? records;

  /// File_Type of the file, if the device has it.
  final String? fileType;

  /// The File object.
  BacnetObject get object =>
      BacnetObject(type: BacnetObjectType.file, instance: instance);

  /// How the file is accessed.
  BacnetFileAccessMethod get accessMethod => data != null
      ? BacnetFileAccessMethod.streamAccess
      : BacnetFileAccessMethod.recordAccess;

  /// Octets of the content.
  int get size =>
      data?.length ??
      records!.fold<int>(0, (size, record) => size + record.length);

  /// The file as JSON (content in base64).
  Map<String, Object?> toJson() => {
    'instance': instance,
    'fileType': ?fileType,
    if (data case final data?) 'data': base64Encode(data),
    if (records case final records?)
      'records': [for (final record in records) base64Encode(record)],
  };

  @override
  bool operator ==(Object other) {
    if (other is! BacnetBackupFile ||
        other.instance != instance ||
        other.fileType != fileType) {
      return false;
    }
    if (data case final data?) {
      return other.data != null && listEquals(other.data!, data);
    }
    final mine = records!;
    final theirs = other.records;
    if (theirs == null || theirs.length != mine.length) return false;
    for (var i = 0; i < mine.length; i++) {
      if (!listEquals(theirs[i], mine[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    instance,
    fileType,
    data == null ? null : Object.hashAll(data!),
    records == null ? null : Object.hashAll(records!.map(Object.hashAll)),
  );

  @override
  String toString() =>
      'BacnetBackupFile(file $instance, $size octets'
      '${records == null ? '' : ' in ${records!.length} records'})';
}
