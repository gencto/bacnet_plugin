import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/requests.dart';
import 'package:test/test.dart';

import '../support/codec_helpers.dart';

void main() {
  group('application values', () {
    test('round trip every application type', () {
      expect(roundTrip(null), isNull);
      expect(roundTrip(true), isTrue);
      expect(roundTrip(false), isFalse);
      for (final v in [0, 1, 255, 256, 65535, 65536, 0xFFFFFFFF, 1 << 40]) {
        expect(roundTrip(v), v, reason: 'unsigned $v');
      }
      for (final v in [-1, -128, -129, -32768, -32769, -2147483648]) {
        expect(roundTrip(v), v, reason: 'signed $v');
      }
      expect(roundTrip(3, tag: BacnetApplicationTag.signedInt), 3);
      expect(roundTrip(72.5), 72.5);
      expect(
        roundTrip(1.0e300, tag: BacnetApplicationTag.doubleValue),
        1.0e300,
      );
      final octets = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
      expect(roundTrip(octets), octets);
      expect(roundTrip('Температура °C ✓'), 'Температура °C ✓');
      final longText = 'x' * 70000;
      expect(roundTrip(longText), longText);
      const bits = BacnetBitString([
        true,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
      ]);
      expect(roundTrip(bits), bits);
      expect(roundTrip(const BacnetBitString([])), const BacnetBitString([]));
      expect(roundTrip(5, tag: BacnetApplicationTag.enumerated), 5);
      const date = BacnetDate(year: 2026, month: 10, day: 1, weekday: 4);
      expect(roundTrip(date), date);
      expect(roundTrip(const BacnetDate()), const BacnetDate());
      const time = BacnetTime(hour: 13, minute: 5, second: 59, hundredths: 99);
      expect(roundTrip(time), time);
      const object = BacnetObject(
        type: BacnetObjectType.device,
        instance: 4194302,
      );
      expect(roundTrip(object), object);
    });

    test('BacnetValue forces the datatype', () {
      final writer = BacnetWriter();
      encodeApplicationValue(writer, const BacnetValue.enumerated(1));
      encodeApplicationValue(writer, const BacnetValue.nullValue());
      encodeApplicationValue(writer, const BacnetValue.unsigned(3));
      expect(hex(writer.toBytes()), '91 01 00 21 03');
    });

    test('rejects values that do not match the forced tag', () {
      expect(
        () => roundTrip('text', tag: BacnetApplicationTag.real),
        throwsA(isA<BacnetEncodeException>()),
      );
      expect(
        () => roundTrip(-1, tag: BacnetApplicationTag.unsignedInt),
        throwsA(isA<BacnetEncodeException>()),
      );
      expect(() => roundTrip(Object()), throwsA(isA<BacnetEncodeException>()));
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
        'AА',
      );
      expect(
        BacnetReader(bytes([0x73, 0x05, 0xB0, 0x43])).readApplicationValue(),
        '°C',
      );
    });
  });

  group('datatype inference', () {
    // value part after object id (5), property id (2) and opening tag (1)
    String encode(int type, int property, Object? value) => hex(
      Uint8List.sublistView(encodeWriteProperty(type, 1, property, value), 8),
    );

    test('present values follow the object type', () {
      expect(
        encode(BacnetObjectType.analogOutput, 85, 75),
        '44 42 96 00 00 3f',
      );
      expect(encode(BacnetObjectType.binaryValue, 85, true), '91 01 3f');
      expect(encode(BacnetObjectType.binaryOutput, 85, 0), '91 00 3f');
      expect(encode(BacnetObjectType.multiStateValue, 85, 3), '21 03 3f');
      expect(encode(BacnetObjectType.integerValue, 85, 3), '31 03 3f');
      expect(encode(BacnetObjectType.analogValue, 85, null), '00 3f');
    });

    test('other properties follow the Dart value or the property', () {
      expect(encode(BacnetObjectType.analogValue, 81, true), '11 3f');
      expect(encode(BacnetObjectType.analogValue, 22, 1), '44 3f 80 00 00 3f');
      expect(encode(BacnetObjectType.analogValue, 117, 62), '91 3e 3f');
      expect(
        encode(BacnetObjectType.analogValue, 28, 'Room'),
        '75 05 00 52 6f 6f 6d 3f',
      );
    });
  });
}
