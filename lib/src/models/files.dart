/// @docImport '../client/bacnet_client.dart';
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Octets read from a File object with stream access (an AtomicReadFile
/// answer, see [BacnetClient.readFileStream]).
@immutable
final class BacnetFileChunk {
  /// Creates a chunk.
  BacnetFileChunk({
    required this.start,
    required List<int> data,
    required this.endOfFile,
  }) : data = Uint8List.fromList(data);

  /// Position of the first octet in the file.
  final int start;

  /// The octets.
  final Uint8List data;

  /// True when the chunk ends at the end of the file.
  final bool endOfFile;

  @override
  bool operator ==(Object other) =>
      other is BacnetFileChunk &&
      other.start == start &&
      other.endOfFile == endOfFile &&
      _bytesEqual(other.data, data);

  @override
  int get hashCode => Object.hash(start, endOfFile, Object.hashAll(data));

  @override
  String toString() =>
      'BacnetFileChunk(start $start, ${data.length} octets'
      '${endOfFile ? ', end of file' : ''})';
}

/// Records read from a File object with record access (an AtomicReadFile
/// answer, see [BacnetClient.readFileRecords]).
@immutable
final class BacnetFileRecords {
  /// Creates the records.
  BacnetFileRecords({
    required this.start,
    required List<List<int>> records,
    required this.endOfFile,
  }) : records = List.unmodifiable(records.map(Uint8List.fromList));

  /// Number of the first record (0 based).
  final int start;

  /// The records.
  final List<Uint8List> records;

  /// True when the last record is the last one of the file.
  final bool endOfFile;

  @override
  bool operator ==(Object other) {
    if (other is! BacnetFileRecords ||
        other.start != start ||
        other.endOfFile != endOfFile ||
        other.records.length != records.length) {
      return false;
    }
    for (var i = 0; i < records.length; i++) {
      if (!_bytesEqual(other.records[i], records[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    start,
    endOfFile,
    Object.hashAll(records.map(Object.hashAll)),
  );

  @override
  String toString() =>
      'BacnetFileRecords(start $start, ${records.length} records'
      '${endOfFile ? ', end of file' : ''})';
}

/// Progress of `readFile` and `writeFile` (BacnetFileTransfer): `done`
/// octets of `total` (null when the size is unknown).
typedef BacnetFileProgress = void Function(int done, int? total);

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
