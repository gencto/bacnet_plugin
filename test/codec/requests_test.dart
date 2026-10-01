import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/requests.dart';
import 'package:test/test.dart';

import '../support/codec_helpers.dart';

void main() {
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
          objectIdentifier: BacnetObject(
            type: BacnetObjectType.analogInput,
            instance: 16,
          ),
          properties: [
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.presentValue,
            ),
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.reliability,
            ),
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
            const BacnetReal(180),
            priority: 8,
          ),
        ),
        '0c 00 80 00 01 19 55 3e 44 43 34 00 00 3f 49 08',
      );
    });

    test('WritePropertyMultiple', () {
      final payload = encodeWritePropertyMultiple(const [
        BacnetWriteAccessSpecification(
          objectIdentifier: BacnetObject(
            type: BacnetObjectType.analogValue,
            instance: 5,
          ),
          listOfProperties: [
            BacnetPropertyValue(
              propertyIdentifier: BacnetPropertyId.presentValue,
              value: BacnetReal(67),
            ),
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

    test('ReadRange', () {
      String encode(BacnetRange range) =>
          hex(encodeReadRange(20, 1, 131, range: range));
      expect(encode(const BacnetRange.all()), '0c 05 00 00 01 19 83');
      expect(
        encode(const BacnetRange.byPosition(1, 4)),
        '0c 05 00 00 01 19 83 3e 21 01 31 04 3f',
      );
      expect(
        encode(const BacnetRange.bySequenceNumber(300, -2)),
        '0c 05 00 00 01 19 83 6e 22 01 2c 31 fe 6f',
      );
      expect(
        encode(BacnetRange.byTime(DateTime(2026, 10, 1, 12, 30), 10)),
        '0c 05 00 00 01 19 83 7e a4 7e 0a 01 04 b4 0c 1e 00 00 31 0a 7f',
      );
    });
  });
}
