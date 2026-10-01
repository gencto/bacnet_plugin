import 'dart:typed_data';

import 'bindings.g.dart';

/// One record of the native event buffer: a `bp_event_header_t` (48 bytes,
/// host byte order) followed by `dataLength` payload bytes.
///
/// [data] is a view into the native buffer: copy it before the buffer is
/// cleared.
final class NativeEvent {
  NativeEvent._(this._header, this.data);

  /// Size of `bp_event_header_t`.
  static const int headerSize = 48;

  final ByteData _header;

  /// Payload (service data, application data or log text).
  final Uint8List data;

  /// Event kind (`BP_EVENT_*`).
  int get kind => _header.getUint8(0);

  /// Service choice.
  int get service => _header.getUint8(1);

  /// Invoke id of the confirmed request.
  int get invokeId => _header.getUint8(2);

  /// Flags (`BP_FLAG_*`).
  int get flags => _header.getUint8(3);

  /// Device instance or [BP_DEVICE_UNKNOWN].
  int get deviceId => _header.getUint32(4, Endian.host);

  /// Kind specific value (error class, reason, object type, max APDU).
  int get a => _header.getUint32(8, Endian.host);

  /// Kind specific value (error code, instance, vendor id).
  int get b => _header.getUint32(12, Endian.host);

  /// Kind specific value (property, segmentation).
  int get c => _header.getUint32(16, Endian.host);

  /// Kind specific value (array index).
  int get d => _header.getInt32(20, Endian.host);

  /// Write priority.
  int get priority => _header.getUint8(24);

  /// Source network number.
  int get sourceNetwork => _header.getUint16(26, Endian.host);

  /// Source MAC address (BACnet/IP: IPv4 + port).
  List<int> get sourceMac => _bytes(28, _header.getUint8(25));

  /// MAC address behind the source router (empty for local sources).
  List<int> get sourceAdr => _bytes(36, _header.getUint8(35));

  /// True when [flag] (`BP_FLAG_*`) is set.
  bool hasFlag(int flag) => flags & flag != 0;

  List<int> _bytes(int offset, int length) => List<int>.generate(
    length.clamp(0, 7),
    (i) => _header.getUint8(offset + i),
    growable: false,
  );
}

/// Iterates over the events of a native event buffer. A truncated trailing
/// record is ignored.
Iterable<NativeEvent> readNativeEvents(Uint8List buffer) sync* {
  var offset = 0;
  while (offset + NativeEvent.headerSize <= buffer.length) {
    final header = ByteData.sublistView(
      buffer,
      offset,
      offset + NativeEvent.headerSize,
    );
    final dataLength = header.getUint16(44, Endian.host);
    final end = offset + NativeEvent.headerSize + dataLength;
    if (end > buffer.length) return;
    yield NativeEvent._(
      header,
      Uint8List.sublistView(buffer, offset + NativeEvent.headerSize, end),
    );
    offset = end;
  }
}
