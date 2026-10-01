import 'dart:math';
import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/services.dart';
import 'package:test/test.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

String hex(Uint8List data) =>
    data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

Object? roundTrip(Object? value, {int? tag}) {
  final writer = BacnetWriter();
  encodeApplicationValue(writer, value, tag: tag);
  return BacnetReader(writer.toBytes()).readApplicationValue();
}

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
      const object = BacnetObject(type: 8, instance: 4194302);
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

  group('service encoders (ASHRAE 135 Annex F)', () {
    test('ReadProperty', () {
      expect(
        hex(encodeReadProperty(BacnetObjectType.analogInput, 5, 85)),
        '0c 00 00 00 05 19 55',
      );
      expect(
        hex(encodeReadProperty(8, 1, 76, arrayIndex: 0)),
        '0c 02 00 00 01 19 4c 29 00',
      );
    });

    test('ReadPropertyMultiple', () {
      final payload = encodeReadPropertyMultiple(const [
        BacnetReadAccessSpecification(
          objectIdentifier: BacnetObject(type: 0, instance: 16),
          properties: [
            BacnetPropertyReference(propertyIdentifier: 85),
            BacnetPropertyReference(propertyIdentifier: 103),
          ],
        ),
      ]);
      expect(hex(payload), '0c 00 00 00 10 1e 09 55 09 67 1f');
    });

    test('WriteProperty with priority', () {
      expect(
        hex(
          encodeWriteProperty(
            BacnetObjectType.analogValue,
            1,
            85,
            180.0,
            priority: 8,
          ),
        ),
        '0c 00 80 00 01 19 55 3e 44 43 34 00 00 3f 49 08',
      );
    });

    test('WritePropertyMultiple', () {
      final payload = encodeWritePropertyMultiple(const [
        BacnetWriteAccessSpecification(
          objectIdentifier: BacnetObject(type: 2, instance: 5),
          listOfProperties: [
            BacnetPropertyValue(propertyIdentifier: 85, value: 67.0),
          ],
        ),
      ]);
      expect(hex(payload), '0c 00 80 00 05 1e 09 55 2e 44 42 86 00 00 2f 1f');
    });

    test('SubscribeCOV and cancellation', () {
      expect(
        hex(
          encodeSubscribeCov(
            subscriberProcessId: 18,
            objectType: 0,
            instance: 10,
            confirmed: true,
            lifetime: 0,
          ),
        ),
        '09 12 1c 00 00 00 0a 29 01 39 00',
      );
      expect(
        hex(
          encodeSubscribeCov(
            subscriberProcessId: 18,
            objectType: 0,
            instance: 10,
            cancel: true,
          ),
        ),
        '09 12 1c 00 00 00 0a',
      );
    });

    test('Who-Is', () {
      expect(hex(encodeWhoIs(lowLimit: 3, highLimit: 3)), '09 03 19 03');
      expect(encodeWhoIs(), isEmpty);
    });

    test('ReadRange by position', () {
      expect(
        hex(
          encodeReadRange(
            20,
            1,
            131,
            type: ReadRangeType.byPosition,
            reference: 1,
            count: 4,
          ),
        ),
        '0c 05 00 00 01 19 83 3e 21 01 31 04 3f',
      );
    });
  });

  group('service decoders', () {
    test('ReadProperty-ACK', () {
      final result = decodeReadPropertyAck(
        bytes([
          0x0C,
          0,
          0,
          0,
          5,
          0x19,
          0x55,
          0x3E,
          0x44,
          0x42,
          0x90,
          0,
          0,
          0x3F,
        ]),
      );
      expect(result.object, const BacnetObject(type: 0, instance: 5));
      expect(result.propertyId, 85);
      expect(result.value, 72.0);
    });

    test('ReadProperty-ACK with an array', () {
      final result = decodeReadPropertyAck(
        bytes([
          0x0C, 0x02, 0, 0, 1, 0x19, 0x4C, 0x3E, //
          0xC4, 0x02, 0, 0, 1, 0xC4, 0, 0, 0, 3, 0xC4, 0x00, 0x80, 0, 1,
          0x3F,
        ]),
      );
      expect(result.value, const [
        BacnetObject(type: 8, instance: 1),
        BacnetObject(type: 0, instance: 3),
        BacnetObject(type: 2, instance: 1),
      ]);
    });

    test('ReadPropertyMultiple-ACK with values and errors', () {
      final result = decodeReadPropertyMultipleAck(
        bytes([
          0x0C, 0, 0, 0, 16, 0x1E, //
          0x29, 0x55, 0x4E, 0x44, 0x42, 0x90, 0, 0, 0x4F,
          0x29, 0x67, 0x5E, 0x91, 0x02, 0x91, 0x20, 0x5F,
          0x1F,
          0x0C, 0x00, 0x80, 0, 2, 0x1E, //
          0x29, 0x4D, 0x4E, 0x75, 0x04, 0x00, 0x41, 0x56, 0x32, 0x4F,
          0x1F,
        ]),
      );
      expect(result['0:16']![85], 72.0);
      final error = result['0:16']![103] as BacnetError;
      expect(error.errorClass, BacnetErrorClass.property);
      expect(error.errorCode, BacnetErrorCode.unknownProperty);
      expect(result['2:2']![77], 'AV2');
    });

    test('COV notification (Annex F.1.4)', () {
      final cov = decodeCovNotification(
        bytes([
          0x09,
          0x12,
          0x1C,
          0x02,
          0x00,
          0x00,
          0x04,
          0x2C,
          0x00,
          0x00,
          0x00,
          0x0A,
          0x39,
          0x00,
          0x4E,
          0x09,
          0x55,
          0x2E,
          0x44,
          0x42,
          0x82,
          0x00,
          0x00,
          0x2F,
          0x09,
          0x6F,
          0x2E,
          0x82,
          0x04,
          0x00,
          0x2F,
          0x4F,
        ]),
      );
      expect(cov.subscriberProcessId, 18);
      expect(cov.initiatingDeviceId, 4);
      expect(cov.monitoredObject, const BacnetObject(type: 0, instance: 10));
      expect(cov.values.first.propertyId, 85);
      expect(cov.values.first.value, 65.0);
      expect(
        cov.values.last.value,
        const BacnetBitString([false, false, false, false]),
      );
    });

    test('ReadRange-ACK with trend log records', () {
      final writer = BacnetWriter()
        ..ctxObjectId(0, 20, 1)
        ..ctxUnsigned(1, 131);
      // result flags: first + last item
      writer.bytes([0x3A, 0x05, 0xC0]);
      writer
        ..ctxUnsigned(4, 2)
        ..opening(5);
      for (var i = 0; i < 2; i++) {
        writer
          ..opening(0)
          ..appDate(const BacnetDate(year: 2026, month: 9, day: 30, weekday: 3))
          ..appTime(BacnetTime(hour: 12, minute: i, second: 0, hundredths: 0))
          ..closing(0)
          ..opening(1)
          ..ctxReal(2, 20.5 + i)
          ..closing(1);
        writer.bytes([0x2A, 0x04, i == 0 ? 0x00 : 0x40]);
      }
      writer
        ..closing(5)
        ..ctxUnsigned(6, 41);

      final result = decodeReadRangeAck(writer.toBytes());
      expect(result.itemCount, 2);
      expect(result.firstSequenceNumber, 41);
      expect(result.moreItems, isFalse);
      final entries = decodeLogRecords(result.items);
      expect(entries, hasLength(2));
      expect(entries[0].timestamp, DateTime(2026, 9, 30, 12));
      expect(entries[0].value, 20.5);
      expect(entries[0].status, 'OK');
      expect(entries[1].value, 21.5);
      expect(entries[1].status, 'FAULT');
    });

    test('complex error payload', () {
      expect(
        decodeComplexError(bytes([0x0E, 0x91, 0x02, 0x91, 0x28, 0x0F, 0x1E])),
        (2, 40),
      );
    });
  });

  group('robustness', () {
    final samples = <Uint8List>[
      bytes([0x0C, 0, 0, 0, 5, 0x19, 0x55, 0x3E, 0x44, 0x42, 0x90, 0, 0, 0x3F]),
      encodeReadPropertyMultiple(const [
        BacnetReadAccessSpecification(
          objectIdentifier: BacnetObject(type: 0, instance: 1),
          properties: [BacnetPropertyReference(propertyIdentifier: 85)],
        ),
      ]),
      bytes([
        0x09,
        0x12,
        0x1C,
        0x02,
        0x00,
        0x00,
        0x04,
        0x2C,
        0x00,
        0x00,
        0x00,
        0x0A,
        0x39,
        0x00,
        0x4E,
        0x09,
        0x55,
        0x2E,
        0x44,
        0x42,
        0x82,
        0x00,
        0x00,
        0x2F,
        0x4F,
      ]),
    ];

    void decodeAll(Uint8List data) {
      for (final decoder in <void Function(Uint8List)>[
        decodeReadPropertyAck,
        decodeReadPropertyMultipleAck,
        decodeReadRangeAck,
        decodeCovNotification,
        decodeComplexError,
        decodeApplicationData,
      ]) {
        try {
          decoder(data);
        } on BacnetDecodeException {
          // expected for malformed input
        }
      }
    }

    test('truncated packets only raise BacnetDecodeException', () {
      for (final sample in samples) {
        for (var length = 0; length < sample.length; length++) {
          decodeAll(Uint8List.sublistView(sample, 0, length));
        }
      }
    });

    test('random and mutated packets only raise BacnetDecodeException', () {
      final random = Random(1234);
      for (var i = 0; i < 20000; i++) {
        final Uint8List data;
        if (i.isEven) {
          data = Uint8List.fromList(
            List.generate(random.nextInt(64), (_) => random.nextInt(256)),
          );
        } else {
          final sample = samples[random.nextInt(samples.length)];
          data = Uint8List.fromList(sample);
          for (var m = 0; m < 1 + random.nextInt(3); m++) {
            data[random.nextInt(data.length)] = random.nextInt(256);
          }
        }
        decodeAll(data);
      }
    });

    test('deeply nested constructed values are bounded', () {
      final data = Uint8List.fromList([
        ...List.filled(200, 0x0E),
        ...List.filled(200, 0x0F),
      ]);
      expect(
        () => BacnetReader(data).readAnyValue(),
        throwsA(isA<BacnetDecodeException>()),
      );
    });
  });
}
