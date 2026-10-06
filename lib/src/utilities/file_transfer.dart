import 'dart:typed_data';

import '../client/bacnet_client.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/cancel_token.dart';
import '../models/bacnet_value.dart';
import '../models/files.dart';

/// Transfers of whole files with AtomicReadFile and AtomicWriteFile.
extension BacnetFileTransfer on BacnetClient {
  /// Reads the whole content of File object [fileInstance] (stream
  /// access), in chunks that fit into one APDU of the device.
  ///
  /// [chunkSize] overrides the chunk size; [onProgress] reports the octets
  /// read and File_Size.
  ///
  /// ```dart
  /// final config = await client.readFile(1234, 1,
  ///     onProgress: (done, total) => print('$done / $total'));
  /// ```
  Future<Uint8List> readFile(
    int deviceId,
    int fileInstance, {
    int? chunkSize,
    BacnetFileProgress? onProgress,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) async {
    final total = await _fileSize(deviceId, fileInstance, timeout);
    final size = chunkSize ?? await _chunkSize(deviceId);
    final data = BytesBuilder(copy: false);
    onProgress?.call(0, total);
    while (true) {
      final chunk = await readFileStream(
        deviceId,
        fileInstance,
        start: data.length,
        count: size,
        timeout: timeout,
        background: background,
        cancelToken: cancelToken,
      );
      data.add(chunk.data);
      onProgress?.call(data.length, total);
      if (chunk.endOfFile || chunk.data.isEmpty) return data.takeBytes();
    }
  }

  /// Writes [data] to File object [fileInstance] from position 0 (stream
  /// access), in chunks that fit into one APDU of the device.
  ///
  /// With [truncate] File_Size is set to the length of [data] afterwards,
  /// removing a longer previous content (the device must allow writing
  /// File_Size).
  Future<void> writeFile(
    int deviceId,
    int fileInstance,
    List<int> data, {
    bool truncate = false,
    int? chunkSize,
    BacnetFileProgress? onProgress,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) async {
    // binds the device and checks that the file exists
    await _fileSize(deviceId, fileInstance, timeout);
    final size = chunkSize ?? await _chunkSize(deviceId);
    final bytes = Uint8List.fromList(data);
    var done = 0;
    onProgress?.call(0, bytes.length);
    while (done < bytes.length) {
      final end = done + size < bytes.length ? done + size : bytes.length;
      await writeFileStream(
        deviceId,
        fileInstance,
        Uint8List.sublistView(bytes, done, end),
        start: done,
        timeout: timeout,
        background: background,
        cancelToken: cancelToken,
      );
      done = end;
      onProgress?.call(done, bytes.length);
    }
    if (truncate) {
      await writeProperty(
        deviceId,
        BacnetObjectType.file,
        fileInstance,
        BacnetPropertyId.fileSize,
        BacnetUnsigned(bytes.length),
        timeout: timeout,
      );
    }
  }

  Future<int?> _fileSize(int deviceId, int instance, Duration? timeout) =>
      readProperty(
        deviceId,
        BacnetObjectType.file,
        instance,
        BacnetPropertyId.fileSize,
        timeout: timeout,
      ).then((value) => value.asInt);

  /// File data that fits into one APDU of the device next to the other
  /// fields of AtomicReadFile/AtomicWriteFile (480, the smallest common
  /// maximum, when the device is not bound).
  Future<int> _chunkSize(int deviceId) async {
    final maxApdu = await deviceMaxApdu(deviceId) ?? 480;
    return maxApdu > 64 ? maxApdu - 32 : 32;
  }
}
