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
}
