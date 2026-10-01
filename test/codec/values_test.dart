import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/requests.dart';
import 'package:test/test.dart';

import '../support/codec_helpers.dart';

void main() {
  group('application values', () {
    test('round trip every application type', () {
      final octets = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
      final values = <BacnetValue>[
        const BacnetNull(),
        const BacnetBoolean(true),
        const BacnetBoolean(false),
        for (final v in [0, 1, 255, 256, 65535, 65536, 0xFFFFFFFF, 1 << 40])
          BacnetUnsigned(v),
        for (final v in [3, -1, -128, -129, -32768, -32769, -2147483648])
          BacnetSigned(v),
        const BacnetReal(72.5),
        const BacnetDouble(1.0e300),
        BacnetOctetString(octets),
        const BacnetCharacterString('Температура °C ✓'),
        BacnetCharacterString('x' * 70000),
        const BacnetBitString([
          true,
          false,
          true,
          true,
          false,
          false,
          true,
          false,
          true,
        ]),
        const BacnetBitString([]),
        const BacnetEnumerated(5),
        const BacnetDate(year: 2026, month: 10, day: 1, weekday: 4),
        const BacnetDate(),
        const BacnetTime(hour: 13, minute: 5, second: 59, hundredths: 99),
        const BacnetObject(type: BacnetObjectType.device, instance: 4194302),
        const BacnetList([BacnetReal(1), BacnetNull(), BacnetUnsigned(2)]),
        const BacnetList([]),
      ];
      for (final value in values) {
        expect(roundTrip(value), value, reason: '$value');
      }
    });

    test('unsigned and enumerated stay distinct', () {
      expect(roundTrip(const BacnetUnsigned(1)), isA<BacnetUnsigned>());
      expect(roundTrip(const BacnetEnumerated(1)), isA<BacnetEnumerated>());
    });

    test('the value class decides the datatype', () {
      final writer = BacnetWriter();
      encodeApplicationValue(writer, const BacnetValue.enumerated(1));
      encodeApplicationValue(writer, const BacnetValue.nullValue());
      encodeApplicationValue(writer, const BacnetValue.unsigned(3));
      encodeApplicationValue(writer, const BacnetValue.signed(3));
      expect(hex(writer.toBytes()), '91 01 00 21 03 31 03');
    });

    test('constructed and context values are written back unchanged', () {
      final value = BacnetConstructedValue(0, [
        const BacnetDate(year: 2026, month: 1, day: 2, weekday: 5),
        BacnetContextValue(1, bytes([0x12, 0x34])),
      ]);
      expect(roundTrip(value), value);
    });

    test('rejects values outside the datatype range', () {
      expect(
        () => roundTrip(
          const BacnetObject(type: BacnetObjectType(1024), instance: 1),
        ),
        throwsA(isA<BacnetEncodeException>()),
      );
    });

    test('rejects integers that do not fit into 63 bits', () {
      BacnetValue decode(List<int> data) =>
          BacnetReader(bytes(data)).readApplicationValue();
      // Unsigned, 8 octets
      expect(
        decode([0x25, 8, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        const BacnetUnsigned(0x7FFFFFFFFFFFFFFF),
      );
      expect(
        () => decode([0x25, 8, 0x80, 0, 0, 0, 0, 0, 0, 0]),
        throwsA(isA<BacnetDecodeException>()),
      );
      // Enumerated, 9 octets with a leading zero
      expect(
        decode([0x95, 9, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
        const BacnetEnumerated(1),
      );
      // Signed, 9 octets
      expect(
        () => decode([0x35, 9, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
        throwsA(isA<BacnetDecodeException>()),
      );
    });

    test('extended tag numbers', () {
      final writer = BacnetWriter()
        ..opening(20)
        ..ctxUnsigned(33, 7)
        ..closing(20);
      expect(hex(writer.toBytes()), 'fe 14 f9 21 07 ff 14');
      final reader = BacnetReader(writer.toBytes())..expectOpening(20);
      expect(reader.readContextUnsigned(33), 7);
      reader.expectClosing(20);
      expect(reader.isAtEnd, isTrue);
    });

    test('decodes UCS-2 and ISO 8859-1 strings', () {
      expect(
        BacnetReader(
          bytes([0x75, 0x05, 0x04, 0x00, 0x41, 0x04, 0x10]),
        ).readApplicationValue(),
        const BacnetCharacterString('AА'),
      );
      expect(
        BacnetReader(bytes([0x73, 0x05, 0xB0, 0x43])).readApplicationValue(),
        const BacnetCharacterString('°C'),
      );
    });
  });

  group('WriteProperty value encoding', () {
    // value part after object id (5), property id (2) and opening tag (1)
    String encode(BacnetValue value) => hex(
      Uint8List.sublistView(
        encodeWriteProperty(BacnetObjectType.analogValue, 1, 85, value),
        8,
      ),
    );

    test('encodes the datatype of the value', () {
      expect(encode(const BacnetReal(75)), '44 42 96 00 00 3f');
      expect(encode(const BacnetEnumerated(1)), '91 01 3f');
      expect(encode(const BacnetUnsigned(3)), '21 03 3f');
      expect(encode(const BacnetSigned(3)), '31 03 3f');
      expect(encode(const BacnetNull()), '00 3f');
      expect(encode(const BacnetBoolean(true)), '11 3f');
      expect(
        encode(const BacnetCharacterString('Room')),
        '75 05 00 52 6f 6f 6d 3f',
      );
      expect(
        encode(const BacnetList([BacnetUnsigned(1), BacnetUnsigned(2)])),
        '21 01 21 02 3f',
      );
    });
  });
}
