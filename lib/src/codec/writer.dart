import 'dart:convert';
import 'dart:typed_data';

import '../core/exceptions.dart';
import '../models/bacnet_value.dart';

/// Growable writer for BACnet encoded data.
class BacnetWriter {
  /// Creates a writer with an initial capacity.
  BacnetWriter([int capacity = 64]) : _buffer = Uint8List(capacity);

  Uint8List _buffer;
  int _length = 0;

  /// Number of written bytes.
  int get length => _length;

  void _ensure(int extra) {
    if (_length + extra <= _buffer.length) return;
    var capacity = _buffer.length * 2;
    while (capacity < _length + extra) {
      capacity *= 2;
    }
    final next = Uint8List(capacity)..setRange(0, _length, _buffer);
    _buffer = next;
  }

  /// Appends one byte.
  void byte(int value) {
    _ensure(1);
    _buffer[_length++] = value & 0xFF;
  }

  /// Appends raw bytes.
  void bytes(List<int> values) {
    _ensure(values.length);
    _buffer.setRange(_length, _length + values.length, values);
    _length += values.length;
  }

  /// Returns a copy of the written bytes.
  Uint8List toBytes() =>
      Uint8List.fromList(Uint8List.sublistView(_buffer, 0, _length));

  void _tag(int number, bool context, int length) {
    var first = context ? 0x08 : 0x00;
    first |= number <= 14 ? number << 4 : 0xF0;
    first |= length <= 4 ? length : 5;
    byte(first);
    if (number > 14) byte(number);
    if (length > 4) {
      if (length <= 253) {
        byte(length);
      } else if (length <= 0xFFFF) {
        byte(254);
        byte(length >> 8);
        byte(length);
      } else {
        byte(255);
        byte(length >> 24);
        byte(length >> 16);
        byte(length >> 8);
        byte(length);
      }
    }
  }

  /// Writes opening tag [number].
  void opening(int number) {
    if (number <= 14) {
      byte((number << 4) | 0x0E);
    } else {
      byte(0xFE);
      byte(number);
    }
  }

  /// Writes closing tag [number].
  void closing(int number) {
    if (number <= 14) {
      byte((number << 4) | 0x0F);
    } else {
      byte(0xFF);
      byte(number);
    }
  }

  static int _unsignedLength(int value) {
    if (value < 0) {
      throw BacnetEncodeException(
        'unsigned value must not be negative: $value',
      );
    }
    var length = 1;
    var v = value >> 8;
    while (v > 0 && length < 8) {
      length++;
      v >>= 8;
    }
    return length;
  }

  void _unsignedContent(int value, int length) {
    for (var i = length - 1; i >= 0; i--) {
      byte(value >> (8 * i));
    }
  }

  static int _signedLength(int value) {
    if (value >= -128 && value <= 127) return 1;
    if (value >= -32768 && value <= 32767) return 2;
    if (value >= -8388608 && value <= 8388607) return 3;
    if (value >= -2147483648 && value <= 2147483647) return 4;
    return 8;
  }

  // ---- application tagged values ------------------------------------------

  /// NULL.
  void appNull() => _tag(BacnetApplicationTag.nullValue, false, 0);

  /// BOOLEAN.
  void appBoolean(bool value) =>
      _tag(BacnetApplicationTag.boolean, false, value ? 1 : 0);

  /// Unsigned.
  void appUnsigned(int value) {
    final length = _unsignedLength(value);
    _tag(BacnetApplicationTag.unsignedInt, false, length);
    _unsignedContent(value, length);
  }

  /// Signed.
  void appSigned(int value) {
    final length = _signedLength(value);
    _tag(BacnetApplicationTag.signedInt, false, length);
    _unsignedContent(value, length);
  }

  /// REAL.
  void appReal(double value) {
    _tag(BacnetApplicationTag.real, false, 4);
    _real(value);
  }

  void _real(double value) {
    final data = ByteData(4)..setFloat32(0, value);
    bytes(data.buffer.asUint8List());
  }

  /// DOUBLE.
  void appDouble(double value) {
    _tag(BacnetApplicationTag.doubleValue, false, 8);
    final data = ByteData(8)..setFloat64(0, value);
    bytes(data.buffer.asUint8List());
  }

  /// Octet string.
  void appOctetString(List<int> value) {
    _tag(BacnetApplicationTag.octetString, false, value.length);
    bytes(value);
  }

  /// Character string (UTF-8).
  void appCharacterString(String value) {
    final encoded = utf8.encode(value);
    _tag(BacnetApplicationTag.characterString, false, encoded.length + 1);
    byte(0); // ISO 10646 (UTF-8)
    bytes(encoded);
  }

  /// Bit string.
  void appBitString(BacnetBitString value) {
    final content = _bitStringContent(value);
    _tag(BacnetApplicationTag.bitString, false, content.length);
    bytes(content);
  }

  static List<int> _bitStringContent(BacnetBitString value) {
    if (value.length == 0) return const [0];
    final byteCount = (value.length + 7) ~/ 8;
    final content = List<int>.filled(byteCount + 1, 0);
    content[0] = byteCount * 8 - value.length;
    for (var i = 0; i < value.length; i++) {
      if (value.bits[i]) content[1 + i ~/ 8] |= 0x80 >> (i % 8);
    }
    return content;
  }

  /// ENUMERATED.
  void appEnumerated(int value) {
    final length = _unsignedLength(value);
    _tag(BacnetApplicationTag.enumerated, false, length);
    _unsignedContent(value, length);
  }

  /// Date.
  void appDate(BacnetDate value) {
    _tag(BacnetApplicationTag.date, false, 4);
    _dateContent(value);
  }

  void _dateContent(BacnetDate value) {
    byte(value.year == null ? 0xFF : value.year! - 1900);
    byte(value.month ?? 0xFF);
    byte(value.day ?? 0xFF);
    byte(value.weekday ?? 0xFF);
  }

  /// Time.
  void appTime(BacnetTime value) {
    _tag(BacnetApplicationTag.time, false, 4);
    byte(value.hour ?? 0xFF);
    byte(value.minute ?? 0xFF);
    byte(value.second ?? 0xFF);
    byte(value.hundredths ?? 0xFF);
  }

  /// Object identifier.
  void appObjectId(int type, int instance) {
    _tag(BacnetApplicationTag.objectIdentifier, false, 4);
    _objectIdContent(type, instance);
  }

  void _objectIdContent(int type, int instance) {
    if (type < 0 || type > 0x3FF || instance < 0 || instance > 0x3FFFFF) {
      throw BacnetEncodeException('invalid object identifier $type:$instance');
    }
    _unsignedContent(((type & 0x3FF) << 22) | (instance & 0x3FFFFF), 4);
  }

  // ---- context tagged values ----------------------------------------------

  /// Context tagged unsigned (also used for enumerated).
  void ctxUnsigned(int number, int value) {
    final length = _unsignedLength(value);
    _tag(number, true, length);
    _unsignedContent(value, length);
  }

  /// Context tagged signed.
  void ctxSigned(int number, int value) {
    final length = _signedLength(value);
    _tag(number, true, length);
    _unsignedContent(value, length);
  }

  /// Context tagged boolean.
  void ctxBoolean(int number, bool value) {
    _tag(number, true, 1);
    byte(value ? 1 : 0);
  }

  /// Context tagged REAL.
  void ctxReal(int number, double value) {
    _tag(number, true, 4);
    _real(value);
  }

  /// Context tagged object identifier.
  void ctxObjectId(int number, int type, int instance) {
    _tag(number, true, 4);
    _objectIdContent(type, instance);
  }

  /// Context tag [number] with raw content octets.
  void ctxRaw(int number, List<int> content) {
    _tag(number, true, content.length);
    bytes(content);
  }

  /// Context tagged character string.
  void ctxCharacterString(int number, String value) {
    final encoded = utf8.encode(value);
    _tag(number, true, encoded.length + 1);
    byte(0);
    bytes(encoded);
  }
}
