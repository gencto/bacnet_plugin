import 'dart:convert';

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
      expect(result.propertyId, BacnetPropertyId.presentValue);
      expect(result.value, const BacnetReal(72));
    });

    test('ReadProperty-ACK with an array', () {
      final result = decodeReadPropertyAck(
        bytes([
          0x0C, 0x02, 0, 0, 1, 0x19, 0x4C, 0x3E, //
          0xC4, 0x02, 0, 0, 1, 0xC4, 0, 0, 0, 3, 0xC4, 0x00, 0x80, 0, 1,
          0x3F,
        ]),
      );
      expect(
        result.value,
        const BacnetList([
          BacnetObject(type: BacnetObjectType.device, instance: 1),
          BacnetObject(type: BacnetObjectType.analogInput, instance: 3),
          BacnetObject(type: BacnetObjectType.analogValue, instance: 1),
        ]),
      );
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
      const ai16 = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 16,
      );
      const av2 = BacnetObject(type: BacnetObjectType.analogValue, instance: 2);
      expect(result.keys, [ai16, av2]);
      expect(
        result[ai16]![BacnetPropertyId.presentValue],
        const BacnetReal(72),
      );
      expect(
        result[ai16]![BacnetPropertyId.reliability],
        const BacnetError(
          BacnetErrorClass.property,
          BacnetErrorCode.unknownProperty,
        ),
      );
      expect(
        result[av2]!.valueOf(BacnetPropertyId.objectName),
        const BacnetCharacterString('AV2'),
      );
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
      expect(cov.values.first.propertyId, BacnetPropertyId.presentValue);
      expect(cov.values.first.value, const BacnetReal(65));
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
      expect(entries[0].datum, const TrendLogValue(BacnetReal(20.5)));
      expect(entries[0].value, const BacnetReal(20.5));
      expect(entries[0].statusFlags, const BacnetStatusFlags());
      expect(entries[1].value, const BacnetReal(21.5));
      expect(entries[1].statusFlags, const BacnetStatusFlags(fault: true));
    });

    test('trend log records of every datum kind', () {
      List<BacnetValue> record(
        void Function(BacnetWriter writer) datum, {
        bool flags = false,
      }) {
        final writer = BacnetWriter()
          ..opening(0)
          ..appDate(const BacnetDate(year: 2026, month: 9, day: 30, weekday: 3))
          ..appTime(const BacnetTime(hour: 0, minute: 0, second: 0))
          ..closing(0)
          ..opening(1);
        datum(writer);
        writer.closing(1);
        final reader = BacnetReader(writer.toBytes());
        return [reader.readAnyValue(), reader.readAnyValue()];
      }

      TrendLogDatum decode(void Function(BacnetWriter writer) datum) =>
          decodeLogRecords(record(datum)).single.datum;

      expect(
        decode((w) => w.ctxRaw(0, [0x05, 0xA0])),
        const TrendLogStatus(logDisabled: true, logInterrupted: true),
      );
      expect(
        decode((w) => w.ctxBoolean(1, true)),
        const TrendLogValue(BacnetBoolean(true)),
      );
      expect(
        decode((w) => w.ctxUnsigned(3, 1)),
        const TrendLogValue(BacnetEnumerated(1)),
      );
      expect(
        decode((w) => w.ctxUnsigned(4, 7)),
        const TrendLogValue(BacnetUnsigned(7)),
      );
      expect(
        decode((w) => w.ctxSigned(5, -7)),
        const TrendLogValue(BacnetSigned(-7)),
      );
      expect(decode((w) => w.ctxRaw(7, [])), const TrendLogValue(BacnetNull()));
      expect(
        decode(
          (w) => w
            ..opening(8)
            ..appEnumerated(BacnetErrorClass.object)
            ..appEnumerated(BacnetErrorCode.unknownObject)
            ..closing(8),
        ),
        const TrendLogFailure(
          BacnetError(BacnetErrorClass.object, BacnetErrorCode.unknownObject),
        ),
      );
      expect(
        decode((w) => w.ctxReal(9, -3600)),
        const TrendLogTimeChange(-3600),
      );
      expect(
        decode(
          (w) => w
            ..opening(10)
            ..appCharacterString('on')
            ..closing(10),
        ),
        const TrendLogValue(BacnetCharacterString('on')),
      );
    });

    test('trend log entries convert to JSON and back', () {
      final entries = [
        TrendLogEntry(
          timestamp: DateTime(2026, 10, 1, 12),
          datum: const TrendLogValue(BacnetReal(21.5)),
          statusFlags: const BacnetStatusFlags(overridden: true),
        ),
        TrendLogEntry(
          timestamp: DateTime(2026, 10, 1, 13),
          datum: const TrendLogStatus(bufferPurged: true),
        ),
        TrendLogEntry(
          timestamp: DateTime(2026, 10, 1, 14),
          datum: const TrendLogFailure(
            BacnetError(BacnetErrorClass.device, BacnetErrorCode.timeout),
          ),
        ),
        TrendLogEntry(
          timestamp: DateTime(2026, 10, 1, 15),
          datum: const TrendLogTimeChange(60),
        ),
      ];
      final data = TrendLogData(
        itemCount: entries.length,
        totalRecords: 9,
        entries: entries,
      );
      final json =
          jsonDecode(jsonEncode(data.toJson())) as Map<String, dynamic>;
      expect(TrendLogData.fromJson(json).entries, entries);
    });

    test('complex error payload', () {
      expect(
        decodeComplexError(bytes([0x0E, 0x91, 0x02, 0x91, 0x28, 0x0F, 0x1E])),
        const BacnetError(BacnetErrorClass.property, BacnetErrorCode(40)),
      );
    });
  });
}
