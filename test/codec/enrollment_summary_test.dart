import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/requests.dart';
import 'package:bacnet_plugin/src/codec/responses.dart';
import 'package:test/test.dart';

import '../support/codec_helpers.dart';

void main() {
  group('GetEnrollmentSummary request (ASHRAE 135 clause 13.12)', () {
    test('acknowledgmentFilter only', () {
      expect(
        hex(
          encodeGetEnrollmentSummary(
            acknowledgmentFilter: BacnetAcknowledgmentFilter.all,
          ),
        ),
        '09 00',
      );
      expect(
        hex(
          encodeGetEnrollmentSummary(
            acknowledgmentFilter: BacnetAcknowledgmentFilter.notAcked,
          ),
        ),
        '09 02',
      );
    });

    test('event state and event type filters', () {
      expect(
        hex(
          encodeGetEnrollmentSummary(
            acknowledgmentFilter: BacnetAcknowledgmentFilter.acked,
            eventStateFilter: BacnetEventStateFilter.active,
            eventTypeFilter: BacnetEventType.outOfRange,
          ),
        ),
        '09 01 29 04 39 05',
      );
    });

    test('priority filter needs both bounds', () {
      expect(
        hex(
          encodeGetEnrollmentSummary(
            acknowledgmentFilter: BacnetAcknowledgmentFilter.all,
            priorityMin: 5,
            priorityMax: 10,
          ),
        ),
        '09 00 4e 09 05 19 0a 4f',
      );
      // only one bound: the priority filter is omitted
      expect(
        hex(
          encodeGetEnrollmentSummary(
            acknowledgmentFilter: BacnetAcknowledgmentFilter.all,
            priorityMin: 5,
          ),
        ),
        '09 00',
      );
      expect(
        hex(
          encodeGetEnrollmentSummary(
            acknowledgmentFilter: BacnetAcknowledgmentFilter.all,
            priorityMax: 10,
          ),
        ),
        '09 00',
      );
    });

    test('notification class filter', () {
      expect(
        hex(
          encodeGetEnrollmentSummary(
            acknowledgmentFilter: BacnetAcknowledgmentFilter.all,
            notificationClassFilter: 7,
          ),
        ),
        '09 00 59 07',
      );
    });

    test('all filters together', () {
      expect(
        hex(
          encodeGetEnrollmentSummary(
            acknowledgmentFilter: BacnetAcknowledgmentFilter.acked,
            eventStateFilter: BacnetEventStateFilter.offnormal,
            eventTypeFilter: BacnetEventType.changeOfState,
            priorityMin: 1,
            priorityMax: 16,
            notificationClassFilter: 2,
          ),
        ),
        '09 01 29 00 39 01 4e 09 01 19 10 4f 59 02',
      );
    });
  });

  group('GetEnrollmentSummary-ACK (ASHRAE 135 clause 13.12)', () {
    test('decodes entries with and without a notification class', () {
      final data =
          (BacnetWriter()
                // entry 1: with notificationClass
                ..appObjectId(BacnetObjectType.analogInput, 2)
                ..appEnumerated(BacnetEventType.outOfRange)
                ..appEnumerated(BacnetEventState.highLimit)
                ..appUnsigned(100)
                ..appUnsigned(4)
                // entry 2: without notificationClass
                ..appObjectId(BacnetObjectType.binaryInput, 9)
                ..appEnumerated(BacnetEventType.changeOfState)
                ..appEnumerated(BacnetEventState.offNormal)
                ..appUnsigned(50))
              .toBytes();
      expect(decodeGetEnrollmentSummaryAck(data), [
        const BacnetEnrollmentSummary(
          object: BacnetObject(type: BacnetObjectType.analogInput, instance: 2),
          eventType: BacnetEventType.outOfRange,
          eventState: BacnetEventState.highLimit,
          priority: 100,
          notificationClass: 4,
        ),
        const BacnetEnrollmentSummary(
          object: BacnetObject(type: BacnetObjectType.binaryInput, instance: 9),
          eventType: BacnetEventType.changeOfState,
          eventState: BacnetEventState.offNormal,
          priority: 50,
        ),
      ]);
    });

    test('an empty ACK decodes to no entries', () {
      expect(decodeGetEnrollmentSummaryAck(Uint8List(0)), isEmpty);
    });

    test('a malformed ACK throws', () {
      // the first field is an enumerated instead of an object identifier
      final malformed =
          (BacnetWriter()
                ..appEnumerated(5)
                ..appEnumerated(5)
                ..appEnumerated(3)
                ..appUnsigned(100))
              .toBytes();
      expect(
        () => decodeGetEnrollmentSummaryAck(malformed),
        throwsA(isA<BacnetDecodeException>()),
      );
      // a truncated entry throws as well
      expect(
        () => decodeGetEnrollmentSummaryAck(bytes([0xc4, 0x00, 0x00, 0x00, 2])),
        throwsA(isA<BacnetDecodeException>()),
      );
    });
  });
}
