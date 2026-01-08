import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:bacnet_plugin/src/native/worker/globals.dart';

import '../../core/types.dart';

/// Decoder for ReadPropertyMultiple (RPM) responses.
///
/// Parses raw BACnet RPM acknowledgment data into structured Maps containing
/// object identifiers and their property values.
class RPMDecoder {
  /// Decodes RPM response data into a map of objects and their properties.
  ///
  /// Returns a Map where keys are 'type:instance' strings and values are Maps
  /// of property ID to property value.
  static Map<String, Map<int, dynamic>> decode(
    ffi.Pointer<ffi.Uint8> data,
    int length,
  ) {
    if (length <= 0) return {};

    final result = <String, Map<int, dynamic>>{};
    final offset = _Offset(0);

    try {
      while (offset.value < length) {
        // 1. Decode Object Identifier (Context Tag 0)
        if (!_isContextTag(data, offset.value, 0)) {
          // If we hit something else, maybe end of packet?
          break;
        }

        final objectId = _decodeObjectId(data, offset);
        final objKey = '${objectId['type']}:${objectId['instance']}';
        final propsMap = <int, dynamic>{};

        // 2. Expect Opening Tag 1 (List of Results)
        if (!_decodeOpeningTag(data, offset, 1)) {
          throw Exception('Expected Opening Tag 1 after Object ID');
        }

        // 3. Decode Properties
        while (offset.value < length) {
          // Check for Closing Tag 1
          if (_isClosingTag(data, offset.value, 1)) {
            offset.value++;
            break;
          }

          // Property Identifier (Context Tag 2)
          if (!_isContextTag(data, offset.value, 2)) {
            throw Exception('Expected Property ID (Tag 2)');
          }
          final propertyId = _decodeEnumerated(data, offset, 2);

          // Optional Array Index (Context Tag 3)
          if (_isContextTag(data, offset.value, 3)) {
            // Unused currently in map, but we must decode to advance offset
            _decodeUnsigned(data, offset, 3);
          }

          // Result Choice: Value (Tag 4) or Error (Tag 5)
          if (_isOpeningTag(data, offset.value, 4)) {
            // Property Value
            offset.value++; // Consume Opening Tag 4

            // Check if it's immediately closing (empty value?)
            if (_isClosingTag(data, offset.value, 4)) {
              propsMap[propertyId] = null;
              offset.value++;
            } else {
              // Decode Application Data
              try {
                final val = _decodeApplicationData(data, offset);
                propsMap[propertyId] = val;
              } on Exception catch (e) {
                propsMap[propertyId] = 'DecodeError: $e';
                // Fast forward to closing tag 4
                _fastForwardToClosingTag(data, offset, 4);
              }

              // Expect Closing Tag 4
              if (!_decodeClosingTag(data, offset, 4)) {
                // Should have been consumed by loop if multiple values or by logic above
              }
            }
          } else if (_isOpeningTag(data, offset.value, 5)) {
            // Property Access Error
            offset.value++; // Consume Opening Tag 5

            final errClass = _decodeEnumerated(data, offset, -1); // App tag
            final errCode = _decodeEnumerated(data, offset, -1);

            propsMap[propertyId] = BacnetError(errClass, errCode);

            if (!_decodeClosingTag(data, offset, 5)) {
              throw Exception('Expected Closing Tag 5');
            }
          } else {
            throw Exception('Expected Value (Tag 4) or Error (Tag 5)');
          }
        }

        result[objKey] = propsMap;
      }
    } on Exception catch (e) {
      // ignore: avoid_print
      logToMain(
        BacnetLogLevel.error,
        'RPM Manual Decode Error: $e (Offset: ${offset.value})',
      );
    }

    return result;
  }

  // --- Primitives ---

  static bool _isContextTag(
    ffi.Pointer<ffi.Uint8> data,
    int offset,
    int tagNumber,
  ) {
    final b = data[offset];
    // if ((b & 0x08) != 0) return true; // Removed buggy short-circuit
    // Actually standard says:
    // Bit 3: Class (0=Application, 1=Context Specific)
    // Bit 7-4: Tag Number
    final isContext = (b & 0x08) != 0;
    final num = (b & 0xF0) >> 4;
    return isContext && num == tagNumber;
  }

  static bool _isOpeningTag(
    ffi.Pointer<ffi.Uint8> data,
    int offset,
    int tagNumber,
  ) {
    final b = data[offset];
    final num = (b & 0xF0) >> 4;
    final isContext = (b & 0x08) != 0;
    final lvt = b & 0x07;
    return isContext && (num == tagNumber) && (lvt == 6); // 6 = Opening Tag
  }

  static bool _isClosingTag(
    ffi.Pointer<ffi.Uint8> data,
    int offset,
    int tagNumber,
  ) {
    final b = data[offset];
    final num = (b & 0xF0) >> 4;
    final isContext = (b & 0x08) != 0;
    final lvt = b & 0x07;
    return isContext && (num == tagNumber) && (lvt == 7); // 7 = Closing Tag
  }

  static bool _decodeOpeningTag(
    ffi.Pointer<ffi.Uint8> data,
    _Offset offset,
    int tagNumber,
  ) {
    if (_isOpeningTag(data, offset.value, tagNumber)) {
      offset.value++;
      return true;
    }
    return false;
  }

  static bool _decodeClosingTag(
    ffi.Pointer<ffi.Uint8> data,
    _Offset offset,
    int tagNumber,
  ) {
    if (_isClosingTag(data, offset.value, tagNumber)) {
      offset.value++;
      return true;
    }
    return false;
  }

  static Map<String, int> _decodeObjectId(
    ffi.Pointer<ffi.Uint8> data,
    _Offset offset,
  ) {
    offset.value++; // Consume Tag byte

    int val = 0;
    for (int i = 0; i < 4; i++) {
      val = (val << 8) | data[offset.value++];
    }
    final type = (val >> 22) & 0x3FF;
    final inst = val & 0x3FFFFF;
    return {'type': type, 'instance': inst};
  }

  static int _decodeEnumerated(
    ffi.Pointer<ffi.Uint8> data,
    _Offset offset,
    // ignore: unused_element
    int contextTag,
  ) {
    final b = data[offset.value++];

    int len = b & 0x07;
    if (len == 5) {
      len = data[offset.value++]; // Extended length
    }

    int val = 0;
    for (int i = 0; i < len; i++) {
      val = (val << 8) | data[offset.value++];
    }
    return val;
  }

  static int _decodeUnsigned(
    ffi.Pointer<ffi.Uint8> data,
    _Offset offset,
    int contextTag,
  ) {
    // Same logic as enumerated
    return _decodeEnumerated(data, offset, contextTag);
  }

  static dynamic _decodeApplicationData(
    ffi.Pointer<ffi.Uint8> data,
    _Offset offset,
  ) {
    // Check if closing tag (end of list of values)
    if ((data[offset.value] & 0x08) != 0 && (data[offset.value] & 0x07) == 7) {
      return null; // Closing tag found
    }

    final tagByte = data[offset.value++];
    final tagNumber = (tagByte & 0xF0) >> 4;
    // final isContext = (tagByte & 0x08) != 0; // Unused
    var len = tagByte & 0x07;

    if (len == 5) {
      len = data[offset.value++];
    }

    // Basic Types
    if (tagNumber == 1) return len == 1; // Boolean
    if (tagNumber == 2) {
      // Unsigned
      int val = 0;
      for (int i = 0; i < len; i++) {
        val = (val << 8) | data[offset.value++];
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

    // Skip unknown
    offset.value += len;
    return 'UnknownTag$tagNumber';
  }

  static void _fastForwardToClosingTag(
    ffi.Pointer<ffi.Uint8> data,
    _Offset offset,
    int tagNumber,
  ) {
    // Scan until we find closing tag
    // Dangerous manual scan
    while (true) {
      if (_isClosingTag(data, offset.value, tagNumber)) break;
      offset.value++;
      if (offset.value > 10000) break; // Safety break
    }
  }
}

class _Offset {
  int value;
  _Offset(this.value);
}
