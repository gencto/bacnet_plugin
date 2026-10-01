import 'dart:convert';
import 'dart:typed_data';

import '../core/exceptions.dart';
import '../models/bacnet_object.dart';
import 'values.dart';

/// A decoded BACnet tag header.
class BacnetTag {
  const BacnetTag._(
    this.number,
    this.isContext,
    this.length, {
    this.isOpening = false,
    this.isClosing = false,
  });

  /// Tag number (application tag or context tag number).
  final int number;

  /// True for context specific tags.
  final bool isContext;

  /// Content length. For application booleans this is the boolean value.
  final int length;

  /// True for an opening tag (context, LVT = 6).
  final bool isOpening;

  /// True for a closing tag (context, LVT = 7).
  final bool isClosing;

  /// True for an application tag.
  bool get isApplication => !isContext;

  @override
  String toString() =>
      'BacnetTag(${isContext ? 'ctx' : 'app'} $number, len $length'
      '${isOpening ? ', open' : ''}${isClosing ? ', close' : ''})';
}

/// Bounds checked reader for BACnet encoded data (ASHRAE 135 clause 20.2).
///
/// Every read validates the remaining length and throws
/// [BacnetDecodeException] instead of reading past the buffer, so malformed
/// or hostile packets can never crash the process.
class BacnetReader {
  /// Creates a reader over `data[offset..end)`.
  BacnetReader(this._data, [int offset = 0, int? end])
    : _offset = offset,
      _end = end ?? _data.length {
    if (_offset < 0 || _end > _data.length || _offset > _end) {
      throw const BacnetDecodeException('invalid buffer range');
    }
  }

  final Uint8List _data;
  int _offset;
  final int _end;
  int _depth = 0;

  /// Maximum nesting of constructed values accepted by the decoder.
  static const int maxNesting = 32;

  /// Current read position.
  int get offset => _offset;

  /// Remaining bytes.
  int get remaining => _end - _offset;

  /// True when all bytes are consumed.
  bool get isAtEnd => _offset >= _end;

  int _u8() {
    if (_offset >= _end) {
      throw BacnetDecodeException('unexpected end of data at $_offset');
    }
    return _data[_offset++];
  }

  void _need(int count) {
    if (count < 0 || _offset + count > _end) {
      throw BacnetDecodeException(
        'need $count bytes at $_offset, only $remaining left',
      );
    }
  }

  /// Returns the next tag without consuming it.
  BacnetTag peekTag() {
    final saved = _offset;
    try {
      return readTag();
    } finally {
      _offset = saved;
    }
  }

  /// Reads a tag header.
  BacnetTag readTag() {
    final first = _u8();
    var number = first >> 4;
    final isContext = (first & 0x08) != 0;
    final lvt = first & 0x07;
    if (number == 0x0F) {
      number = _u8();
    }
    if (isContext && lvt == 6) {
      return BacnetTag._(number, true, 0, isOpening: true);
    }
    if (isContext && lvt == 7) {
      return BacnetTag._(number, true, 0, isClosing: true);
    }
    if (!isContext && number == BacnetApplicationTag.boolean) {
      // the value lives in the LVT field, no content octets follow
      return BacnetTag._(number, false, lvt);
    }
    var length = lvt;
    if (lvt == 5) {
      length = _u8();
      if (length == 254) {
        length = (_u8() << 8) | _u8();
      } else if (length == 255) {
        length = (_u8() << 24) | (_u8() << 16) | (_u8() << 8) | _u8();
      }
    }
    _need(length);
    return BacnetTag._(number, isContext, length);
  }

  /// True when the next tag is context tag [number] (not opening/closing).
  bool nextIsContext(int number) {
    if (isAtEnd) return false;
    final tag = peekTag();
    return tag.isContext &&
        tag.number == number &&
        !tag.isOpening &&
        !tag.isClosing;
  }

  /// True when the next tag is opening tag [number].
  bool nextIsOpening(int number) {
    if (isAtEnd) return false;
    final tag = peekTag();
    return tag.isOpening && tag.number == number;
  }

  /// True when the next tag is closing tag [number].
  bool nextIsClosing(int number) {
    if (isAtEnd) return false;
    final tag = peekTag();
    return tag.isClosing && tag.number == number;
  }

  /// Consumes opening tag [number] or throws.
  void expectOpening(int number) {
    final tag = readTag();
    if (!tag.isOpening || tag.number != number) {
      throw BacnetDecodeException('expected opening tag $number, got $tag');
    }
  }

  /// Consumes closing tag [number] or throws.
  void expectClosing(int number) {
    final tag = readTag();
    if (!tag.isClosing || tag.number != number) {
      throw BacnetDecodeException('expected closing tag $number, got $tag');
    }
  }

  BacnetTag _expectContext(int number) {
    final tag = readTag();
    if (!tag.isContext ||
        tag.number != number ||
        tag.isOpening ||
        tag.isClosing) {
      throw BacnetDecodeException('expected context tag $number, got $tag');
    }
    return tag;
  }

  /// Reads `length` raw bytes (copied).
  Uint8List readBytes(int length) {
    _need(length);
    final bytes = Uint8List.fromList(
      Uint8List.sublistView(_data, _offset, _offset + length),
    );
    _offset += length;
    return bytes;
  }

  int _unsigned(int length) {
    _need(length);
    var value = 0;
    for (var i = 0; i < length; i++) {
      value = (value << 8) | _data[_offset++];
    }
    return value;
  }

  int _signed(int length) {
    if (length == 0) return 0;
    _need(length);
    var value = _data[_offset] & 0x80 != 0 ? -1 : 0;
    for (var i = 0; i < length; i++) {
      value = (value << 8) | _data[_offset++];
    }
    return value;
  }

  /// Reads context tag [number] as unsigned/enumerated.
  int readContextUnsigned(int number) =>
      _unsigned(_expectContext(number).length);

  /// Reads context tag [number] as signed.
  int readContextSigned(int number) => _signed(_expectContext(number).length);

  /// Reads context tag [number] as boolean.
  bool readContextBoolean(int number) {
    final tag = _expectContext(number);
    return _unsigned(tag.length) != 0;
  }

  /// Reads context tag [number] as REAL.
  double readContextReal(int number) {
    final tag = _expectContext(number);
    if (tag.length != 4) {
      throw BacnetDecodeException('REAL needs 4 octets, got ${tag.length}');
    }
    return _real();
  }

  /// Reads context tag [number] as object identifier.
  BacnetObject readContextObjectId(int number) {
    final tag = _expectContext(number);
    if (tag.length != 4) {
      throw const BacnetDecodeException('object id needs 4 octets');
    }
    return _objectId();
  }

  /// Reads context tag [number] as bit string.
  BacnetBitString readContextBitString(int number) =>
      _bitString(_expectContext(number).length);

  /// Reads context tag [number] if present, as unsigned.
  int? readOptionalContextUnsigned(int number) =>
      nextIsContext(number) ? readContextUnsigned(number) : null;

  double _real() {
    _need(4);
    final value = ByteData.sublistView(
      _data,
      _offset,
      _offset + 4,
    ).getFloat32(0);
    _offset += 4;
    return value;
  }

  double _double() {
    _need(8);
    final value = ByteData.sublistView(
      _data,
      _offset,
      _offset + 8,
    ).getFloat64(0);
    _offset += 8;
    return value;
  }

  BacnetObject _objectId() {
    final value = _unsigned(4);
    return BacnetObject(
      type: (value >> 22) & 0x3FF,
      instance: value & 0x3FFFFF,
    );
  }

  BacnetBitString _bitString(int length) {
    if (length == 0) return const BacnetBitString(<bool>[]);
    _need(length);
    final unused = _data[_offset++] & 0x07;
    final bits = <bool>[];
    for (var i = 1; i < length; i++) {
      final byte = _data[_offset++];
      final count = i == length - 1 ? 8 - unused : 8;
      for (var b = 0; b < count; b++) {
        bits.add((byte & (0x80 >> b)) != 0);
      }
    }
    return BacnetBitString(List.unmodifiable(bits));
  }

  String _characterString(int length) {
    if (length == 0) return '';
    _need(length);
    final charset = _data[_offset];
    final start = _offset + 1;
    final end = _offset + length;
    _offset = end;
    final content = Uint8List.sublistView(_data, start, end);
    switch (charset) {
      case 0: // ISO 10646 UTF-8
        return utf8.decode(content, allowMalformed: true);
      case 4: // UCS-2, big endian
        final units = <int>[
          for (var i = 0; i + 1 < content.length; i += 2)
            (content[i] << 8) | content[i + 1],
        ];
        return String.fromCharCodes(units);
      case 3: // UCS-4, big endian
        final runes = <int>[
          for (var i = 0; i + 3 < content.length; i += 4)
            _validRune(
              (content[i] << 24) |
                  (content[i + 1] << 16) |
                  (content[i + 2] << 8) |
                  content[i + 3],
            ),
        ];
        return String.fromCharCodes(runes);
      case 5: // ISO 8859-1
        return latin1.decode(content);
      default:
        return utf8.decode(content, allowMalformed: true);
    }
  }

  /// Replaces code points outside Unicode (or surrogates) with U+FFFD.
  static int _validRune(int rune) =>
      (rune < 0 || rune > 0x10FFFF || (rune >= 0xD800 && rune <= 0xDFFF))
      ? 0xFFFD
      : rune;

  BacnetDate _date() {
    _need(4);
    int? spec(int v) => v == 0xFF ? null : v;
    final year = _data[_offset];
    final date = BacnetDate(
      year: year == 0xFF ? null : year + 1900,
      month: spec(_data[_offset + 1]),
      day: spec(_data[_offset + 2]),
      weekday: spec(_data[_offset + 3]),
    );
    _offset += 4;
    return date;
  }

  BacnetTime _time() {
    _need(4);
    int? spec(int v) => v == 0xFF ? null : v;
    final time = BacnetTime(
      hour: spec(_data[_offset]),
      minute: spec(_data[_offset + 1]),
      second: spec(_data[_offset + 2]),
      hundredths: spec(_data[_offset + 3]),
    );
    _offset += 4;
    return time;
  }

  /// Decodes the content of application tag [tag] that was just read.
  Object? decodeApplicationContent(BacnetTag tag) {
    switch (tag.number) {
      case BacnetApplicationTag.nullValue:
        return null;
      case BacnetApplicationTag.boolean:
        return tag.length != 0;
      case BacnetApplicationTag.unsignedInt:
      case BacnetApplicationTag.enumerated:
        return _unsigned(tag.length);
      case BacnetApplicationTag.signedInt:
        return _signed(tag.length);
      case BacnetApplicationTag.real:
        if (tag.length != 4) throw const BacnetDecodeException('bad REAL');
        return _real();
      case BacnetApplicationTag.doubleValue:
        if (tag.length != 8) throw const BacnetDecodeException('bad DOUBLE');
        return _double();
      case BacnetApplicationTag.octetString:
        return readBytes(tag.length);
      case BacnetApplicationTag.characterString:
        return _characterString(tag.length);
      case BacnetApplicationTag.bitString:
        return _bitString(tag.length);
      case BacnetApplicationTag.date:
        if (tag.length != 4) throw const BacnetDecodeException('bad Date');
        return _date();
      case BacnetApplicationTag.time:
        if (tag.length != 4) throw const BacnetDecodeException('bad Time');
        return _time();
      case BacnetApplicationTag.objectIdentifier:
        if (tag.length != 4) throw const BacnetDecodeException('bad ObjectId');
        return _objectId();
      default:
        // reserved application tags: keep the raw content
        return BacnetContextValue(tag.number, readBytes(tag.length));
    }
  }

  /// Reads one application tagged value.
  Object? readApplicationValue() {
    final tag = readTag();
    if (tag.isContext) {
      throw BacnetDecodeException('expected application tag, got $tag');
    }
    return decodeApplicationContent(tag);
  }

  /// Reads one value of any kind: application values are decoded, context
  /// primitives are returned as [BacnetContextValue] and constructed values
  /// as [BacnetConstructedValue].
  Object? readAnyValue() {
    final tag = readTag();
    if (tag.isApplication) {
      return decodeApplicationContent(tag);
    }
    if (tag.isOpening) {
      return BacnetConstructedValue(
        tag.number,
        readValuesUntilClosing(tag.number),
      );
    }
    if (tag.isClosing) {
      throw BacnetDecodeException('unexpected closing tag ${tag.number}');
    }
    return BacnetContextValue(tag.number, readBytes(tag.length));
  }

  /// Reads values until closing tag [number] and consumes the closing tag.
  List<Object?> readValuesUntilClosing(int number) {
    if (++_depth > maxNesting) {
      throw const BacnetDecodeException('constructed values nested too deep');
    }
    try {
      final values = <Object?>[];
      while (true) {
        if (isAtEnd) {
          throw BacnetDecodeException('missing closing tag $number');
        }
        final tag = peekTag();
        if (tag.isClosing && tag.number == number) {
          readTag();
          return values;
        }
        values.add(readAnyValue());
      }
    } finally {
      _depth--;
    }
  }

  /// Skips one complete value (including nested constructed values).
  void skipValue() {
    final tag = readTag();
    if (tag.isOpening) {
      readValuesUntilClosing(tag.number);
    } else if (!tag.isClosing &&
        !(tag.isApplication && tag.number == BacnetApplicationTag.boolean)) {
      _need(tag.length);
      _offset += tag.length;
    }
  }

  // ---- decoders for raw context content -----------------------------------

  /// Decodes big endian unsigned content octets.
  static int unsignedFrom(Uint8List bytes) {
    var value = 0;
    for (final b in bytes) {
      value = (value << 8) | b;
    }
    return value;
  }

  /// Decodes big endian two's complement content octets.
  static int signedFrom(Uint8List bytes) {
    if (bytes.isEmpty) return 0;
    var value = bytes[0] & 0x80 != 0 ? -1 : 0;
    for (final b in bytes) {
      value = (value << 8) | b;
    }
    return value;
  }

  /// Decodes REAL content octets.
  static double realFrom(Uint8List bytes) {
    if (bytes.length != 4) throw const BacnetDecodeException('bad REAL');
    return ByteData.sublistView(bytes).getFloat32(0);
  }

  /// Decodes bit string content octets.
  static BacnetBitString bitStringFrom(Uint8List bytes) =>
      BacnetReader(bytes)._bitString(bytes.length);

  /// Decodes character string content octets.
  static String characterStringFrom(Uint8List bytes) =>
      BacnetReader(bytes)._characterString(bytes.length);
}

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

  /// Context tagged character string.
  void ctxCharacterString(int number, String value) {
    final encoded = utf8.encode(value);
    _tag(number, true, encoded.length + 1);
    byte(0);
    bytes(encoded);
  }
}
