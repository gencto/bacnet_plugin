import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/responses.dart';
import 'package:test/test.dart';

import '../support/codec_helpers.dart';

void main() {
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
      expect(
        result.object,
        const BacnetObject(type: BacnetObjectType.analogInput, instance: 5),
      );
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
        BacnetObject(type: BacnetObjectType.device, instance: 1),
        BacnetObject(type: BacnetObjectType.analogInput, instance: 3),
        BacnetObject(type: BacnetObjectType.analogValue, instance: 1),
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
      expect(
        cov.monitoredObject,
        const BacnetObject(type: BacnetObjectType.analogInput, instance: 10),
      );
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
}
