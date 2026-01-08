import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

/// Decodes BACnet application data from native memory.
///
/// Parses BACnet-encoded data and returns Dart objects based on
/// the BACnet application tag type.
dynamic decodeApplicationData(
  ffi.Pointer<ffi.Uint8> data,
  int len,
  int startOffset,
) {
  int offset = startOffset;
  if (offset >= len) return null;

  final tagByte = data[offset++];
  final tagNumber = (tagByte & 0xF0) >> 4;
  final lenValueType = tagByte & 0x07;

  if ((tagByte & 0x08) != 0) {
    // Check for Closing Tag (LVT=7) or other context tags
    if (lenValueType == 7) return null;
    return 'Context Tag $tagNumber';
  }

  int contentLen = lenValueType;
  if (contentLen == 5) {
    if (offset >= len) return null;
    contentLen = data[offset++];
  }

  if (tagNumber == 1) return lenValueType == 1; // Boolean
  if (tagNumber == 2) {
    // Unsigned
    int val = 0;
    for (int i = 0; i < contentLen; i++) {
      val = (val << 8) | data[offset++];
    }
    return val;
  }
  if (tagNumber == 3) {
    // Signed
    int val = 0;
    for (int i = 0; i < contentLen; i++) {
      val = (val << 8) | data[offset++];
    }
    // 32-bit sign extension
    if (contentLen <= 4 &&
        contentLen > 0 &&
        (val & (1 << (contentLen * 8 - 1))) != 0) {
      val -= 1 << (contentLen * 8);
    }
    return val;
  }
  if (tagNumber == 4) {
    // Real
    final list = Uint8List(4);
    for (int i = 0; i < 4; i++) {
      list[i] = data[offset + i];
    }
    return ByteData.sublistView(list).getFloat32(0, Endian.big);
  }
  if (tagNumber == 7) {
    // String
    offset++; // Encoding byte skip
    final strLen = contentLen - 1;
    final bytes = <int>[];
    for (int i = 0; i < strLen; i++) {
      bytes.add(data[offset + i]);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
  if (tagNumber == 9) {
    // Enumerated
    int val = 0;
    for (int i = 0; i < contentLen; i++) {
      val = (val << 8) | data[offset++];
    }
    return val;
  }
  if (tagNumber == 8) {
    // BitString
    int unused = data[offset];
    return 'BitString ($contentLen bytes, $unused unused)';
  }
  if (tagNumber == 12) {
    // Object ID
    int val = 0;
    for (int i = 0; i < 4; i++) {
      val = (val << 8) | data[offset++];
    }
    final type = (val >> 22) & 0x3FF;
    final inst = val & 0x3FFFFF;
    return {'type': type, 'instance': inst};
  }

  // Time (11)
  if (tagNumber == 11 && contentLen == 4) {
    final hour = data[offset];
    final min = data[offset + 1];
    final sec = data[offset + 2];
    final hundredths = data[offset + 3];
    return '$hour:$min:$sec.$hundredths';
  }
  // Date (10)
  if (tagNumber == 10 && contentLen == 4) {
    final year = data[offset] + 1900;
    final month = data[offset + 1];
    final day = data[offset + 2];
    final wday = data[offset + 3];
    return '$year-$month-$day (W:$wday)';
  }

  return 'Tag $tagNumber';
}
