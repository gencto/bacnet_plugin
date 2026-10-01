import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/requests.dart';
import 'package:bacnet_plugin/src/codec/responses.dart';
import 'package:test/test.dart';

import '../support/alarm_vectors.dart' show hexBytes;

// Encodings written out from the ASN.1 of ASHRAE 135 clause 21
// (SubscribeCOVPropertyMultiple-Request, COVNotificationMultiple-Request,
// SubscribeCOVPropertyMultiple-Error); bacnet-stack has no encoder.
const _subscribe =
    '0907' // subscriber process 7
    '1900' // unconfirmed notifications
    '2a0258' // lifetime 600 s
    '3905' // max notification delay 5 s
    '4e'
    '0c00000001' // analog-input 1
    '1e'
    '0e09550f1c3f0000002900' // present-value, increment 0.5
    '0e096f0f2901' // status-flags, timestamped
    '1f'
    '0c01400002' // binary-value 2
    '1e0e09550f29001f'
    '4f';
const _cancel = '09074e0c000000011e0e09550f29001f4f';
const _notification =
    '0907' // subscriber process 7
    '1c020004d2' // device 1234
    '2978' // 120 s remaining
    '3ea47e0a0104b40c1e0f003f' // 2026-10-01 (Thursday) 12:30:15.00
    '4e'
    '0c00000001' // analog-input 1
    '1e'
    '09552e4441ac00002f' // present-value 21.5
    '3c0c1e0e32' // changed at 12:30:14.50
    '096f2e8204002f' // status-flags
    '1f'
    '0c01400002' // binary-value 2
    '1e09552e91012f1f' // present-value active
    '4f';
const _error =
    '0e910591000f' // services, other
    '1e0c00000001' // analog-input 1
    '1e09551f' // present-value
    '2e910291202f' // property, unknown-property
    '1f';

const _ai1 = BacnetObject(type: BacnetObjectType.analogInput, instance: 1);
const _bv2 = BacnetObject(type: BacnetObjectType.binaryValue, instance: 2);

String _hex(Uint8List data) =>
    data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final specifications = [
    BacnetCovSubscriptionSpecification(_ai1, const [
      BacnetCovReference(BacnetPropertyId.presentValue, covIncrement: 0.5),
      BacnetCovReference(BacnetPropertyId.statusFlags, timestamped: true),
    ]),
    BacnetCovSubscriptionSpecification(_bv2, const [
      BacnetCovReference(BacnetPropertyId.presentValue),
    ]),
  ];

  group('SubscribeCOVPropertyMultiple', () {
    test('encodes subscriptions', () {
      expect(
        _hex(
          encodeSubscribeCovPropertyMultiple(
            subscriberProcessId: 7,
            specifications: specifications,
            confirmed: false,
            lifetime: 600,
            maxNotificationDelay: 5,
          ),
        ),
        _subscribe,
      );
    });

    test('encodes a cancellation without lifetime', () {
      expect(
        _hex(
          encodeSubscribeCovPropertyMultiple(
            subscriberProcessId: 7,
            specifications: [
              BacnetCovSubscriptionSpecification(_ai1, const [
                BacnetCovReference(BacnetPropertyId.presentValue),
              ]),
            ],
          ),
        ),
        _cancel,
      );
    });

    test('decodes what it encodes', () {
      final request = decodeSubscribeCovPropertyMultiple(hexBytes(_subscribe));
      expect(request.subscriberProcessId, 7);
      expect(request.confirmed, isFalse);
      expect(request.lifetime, 600);
      expect(request.maxNotificationDelay, 5);
      expect(request.specifications, specifications);
      final cancel = decodeSubscribeCovPropertyMultiple(hexBytes(_cancel));
      expect(cancel.confirmed, isNull);
      expect(cancel.lifetime, isNull);
    });

    test('rejects empty subscriptions', () {
      expect(
        () => encodeSubscribeCovPropertyMultiple(
          subscriberProcessId: 1,
          specifications: const [],
        ),
        throwsArgumentError,
      );
      expect(
        () => BacnetCovSubscriptionSpecification(_ai1, const []),
        throwsArgumentError,
      );
      expect(
        () => decodeSubscribeCovPropertyMultiple(
          hexBytes('09074e0c000000011e1f4f'),
        ),
        throwsA(isA<BacnetDecodeException>()),
      );
    });

    test('decodes the first failed subscription of the error', () {
      final error = decodeComplexError(
        hexBytes(_error),
        service: BacnetConfirmedService.subscribeCovPropertyMultiple,
      );
      expect(error.error.errorClass, BacnetErrorClass.services);
      expect(error.error.errorCode, BacnetErrorCode.other);
      expect(
        error.firstFailedSubscription,
        const BacnetFailedCovSubscription(
          object: _ai1,
          property: BacnetPropertyId.presentValue,
          errorClass: BacnetErrorClass.property,
          errorCode: BacnetErrorCode.unknownProperty,
        ),
      );
      expect(error.firstFailedElement, isNull);
    });
  });

  group('COVNotificationMultiple', () {
    final timestamp = BacnetDateTime(
      BacnetDate.fromDateTime(DateTime(2026, 10)),
      const BacnetTime(hour: 12, minute: 30, second: 15, hundredths: 0),
    );
    const changed = BacnetTime(
      hour: 12,
      minute: 30,
      second: 14,
      hundredths: 50,
    );

    test('encodes notifications', () {
      expect(
        _hex(
          encodeCovNotificationMultiple(
            subscriberProcessId: 7,
            initiatingDeviceId: 1234,
            timeRemaining: 120,
            timestamp: timestamp,
            notifications: [
              (
                object: _ai1,
                values: const [
                  CovPropertyValue(
                    propertyId: BacnetPropertyId.presentValue,
                    value: BacnetReal(21.5),
                  ),
                  CovPropertyValue(
                    propertyId: BacnetPropertyId.statusFlags,
                    value: BacnetBitString([false, false, false, false]),
                  ),
                ],
                changeTimes: const {BacnetPropertyId.presentValue: changed},
              ),
              (
                object: _bv2,
                values: const [
                  CovPropertyValue(
                    propertyId: BacnetPropertyId.presentValue,
                    value: BacnetEnumerated(1),
                  ),
                ],
                changeTimes: const {},
              ),
            ],
          ),
        ),
        _notification,
      );
    });

    test('decodes notifications', () {
      final cov = decodeCovNotificationMultiple(hexBytes(_notification));
      expect(cov.subscriberProcessId, 7);
      expect(cov.initiatingDeviceId, 1234);
      expect(cov.timeRemaining, 120);
      expect(cov.timestamp, timestamp);
      expect(cov.notifications.map((n) => n.object), [_ai1, _bv2]);
      final ai = cov.notifications.first;
      expect(ai.values.map((v) => v.propertyId), [
        BacnetPropertyId.presentValue,
        BacnetPropertyId.statusFlags,
      ]);
      expect(ai.values.first.value, const BacnetReal(21.5));
      expect(ai.changeTimes, {BacnetPropertyId.presentValue: changed});
      expect(
        cov.notifications.last.values.single.value,
        const BacnetEnumerated(1),
      );
    });

    test('decodes notifications without timestamp', () {
      final cov = decodeCovNotificationMultiple(
        hexBytes('090f1c020004d229004e0c000000011e09552e4441ac00002f1f4f'),
      );
      expect(cov.timestamp, isNull);
      expect(cov.timeRemaining, 0);
      expect(cov.notifications.single.changeTimes, isEmpty);
    });

    test('rejects malformed notifications', () {
      for (final hex in [
        // time of change of 3 octets
        '09071c020004d229784e0c000000011e09552e4441ac00002f3b0c1e0e1f4f',
        // timestamp without the time
        '09071c020004d229783ea47e0a01043f4e4f',
        // missing closing tag
        '09071c020004d229784e0c000000011e',
      ]) {
        expect(
          () => decodeCovNotificationMultiple(hexBytes(hex)),
          throwsA(isA<BacnetDecodeException>()),
          reason: hex,
        );
      }
    });
  });
}
