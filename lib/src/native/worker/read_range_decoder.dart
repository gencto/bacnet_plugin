import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/native/worker/globals.dart';

/// Decoder for ReadRange responses.
class ReadRangeDecoder {
  /// Decodes ReadRange response data.
  ///
  /// Returns a map containing:
  /// - flags: int
  /// - count: int
  /// - firstSequence: int (optional)
  /// - data: `List<dynamic>`
  static Map<String, dynamic> decode(ffi.Pointer<ffi.Uint8> data, int length) {
    final result = <String, dynamic>{
      'flags': 0,
      'count': 0,
      'data': <dynamic>[],
    };
    final offset = _Offset(0);

    try {
      while (offset.value < length) {
        final tagByte = data[offset.value];
        final tagNumber = (tagByte & 0xF0) >> 4;
        final isContext = (tagByte & 0x08) != 0;
        final lvt = tagByte & 0x07;

        if (isContext) {
          if (tagNumber == 3) {
            // ResultFlags (BitString)
            // Expecting Tag 3 (0x3X)
            offset.value++;
            int len = lvt;
            if (len == 5) len = data[offset.value++];
            if (len > 0) {
              // Bitstring: Unused bits (1 byte) + Data
              offset.value++; // Skip unused bits byte
              if (len > 1) {
                result['flags'] = data[offset.value];
              }
              offset.value += len - 1;
            }
          } else if (tagNumber == 4) {
            // ItemCount
            result['count'] = _decodeUnsigned(data, offset);
          } else if (tagNumber == 5) {
            // FirstSequenceNumber (Optional)
            result['firstSequence'] = _decodeUnsigned(data, offset);
          } else if (tagNumber == 6) {
            // ItemData (List of Values)
            if (lvt == 6) {
              // Opening Tag
              offset.value++;
              final items = <dynamic>[];
              while (offset.value < length) {
                if (_isClosingTag(data, offset.value, 6)) {
                  offset.value++;
                  break;
                }
                try {
                  final val = _decodeApplicationData(data, offset);
                  if (val != null) {
                    items.add(val);
                  }
                } on Exception {
                  // If decode fails, try to skip or break
                  break;
                }
              }
              result['data'] = items;
            } else {
              // Should be constructed?
              offset.value++;
            }
          } else {
            // Unknown context tag, skip
            offset.value++;
          }
        } else {
          // Non-context tag? Probably application data directly?
          // Should not happen at top level of ReadRangeAck.
          offset.value++;
        }
      }
    } on Exception catch (e) {
      // ignore: avoid_print
      logToMain(BacnetLogLevel.error, 'ReadRange Decode Error: $e');
    }

    return result;
  }

  static int _decodeUnsigned(ffi.Pointer<ffi.Uint8> data, _Offset offset) {
    final b = data[offset.value++];
    int len = b & 0x07;
    if (len == 5) len = data[offset.value++];

    int val = 0;
    for (int i = 0; i < len; i++) {
      val = (val << 8) | data[offset.value++];
    }
    return val;
  }

  static bool _isClosingTag(
    ffi.Pointer<ffi.Uint8> data,
    int offset,
    int tagNumber,
  ) {
    if (offset >= 1024 * 1024) return true; // Bounds check safety
    final b = data[offset];
    final num = (b & 0xF0) >> 4;
    final isContext = (b & 0x08) != 0;
    final lvt = b & 0x07;
    return isContext && (num == tagNumber) && (lvt == 7);
  }

  static dynamic _decodeApplicationData(
    ffi.Pointer<ffi.Uint8> data,
    _Offset offset,
  ) {
    // Check if closing tag (end of list of values)
    if (_isClosingTag(data, offset.value, 6)) {
      return null;
    }

    final tagByte = data[offset.value++];
    final tagNumber = (tagByte & 0xF0) >> 4;
    var len = tagByte & 0x07;

    if (len == 5) {
      len = data[offset.value++];
    }

    if (tagNumber == 0) return null; // Null
    if (tagNumber == 1) return len == 1; // Boolean
    if (tagNumber == 2) {
      // Unsigned
      int val = 0;
      for (int i = 0; i < len; i++) {
        val = (val << 8) | data[offset.value++];
      }
      return val;
    }
    if (tagNumber == 3) {
      // Signed
      int val = 0;
      for (int i = 0; i < len; i++) {
        val = (val << 8) | data[offset.value++];
      }
      // 32-bit sign extension
      if (len <= 4 && len > 0 && (val & (1 << (len * 8 - 1))) != 0) {
        val -= 1 << (len * 8);
      }
      return val;
    }
    if (tagNumber == 4) {
      // Real
      final list = Uint8List(4);
      for (int i = 0; i < 4; i++) {
        list[i] = data[offset.value++];
      }
      return ByteData.sublistView(list).getFloat32(0, Endian.big);
    }
    if (tagNumber == 7) {
      // String
      offset.value++; // Skip encoding
      final bytes = <int>[];
      for (int i = 0; i < len - 1; i++) {
        bytes.add(data[offset.value++]);
      }
      return utf8.decode(bytes);
    }
    if (tagNumber == 9) {
      // Enumerated
      int val = 0;
      for (int i = 0; i < len; i++) {
        val = (val << 8) | data[offset.value++];
      }
      return val;
    }
    if (tagNumber == 12) {
      // Object ID
      int val = 0;
      for (int i = 0; i < 4; i++) {
        val = (val << 8) | data[offset.value++];
      }
      final type = (val >> 22) & 0x3FF;
      final inst = val & 0x3FFFFF;
      return {'type': type, 'instance': inst};
    }

    // Skip unknown or complex types
    offset.value += len;
    return 'UnknownTag$tagNumber';
  }
}

class _Offset {
  int value;
  _Offset(this.value);
}
