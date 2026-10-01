import 'dart:math';
import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/requests.dart';
import 'package:bacnet_plugin/src/codec/responses.dart';
import 'package:test/test.dart';

import '../support/alarm_vectors.dart';
import '../support/codec_helpers.dart';

const _youAre =
    '220104751000526f6f6d20436f6e74726f6c6c6572750800534e2d30303432'
    'c4020004d26506c0a80114bac0';
const _writeGroup =
    '091719082e09012e44429700002f090219042e21032f09032e002f09042e112f2f3901';

const _subscribeCovMultiple =
    '090719002a025839054e0c000000011e0e09550f1c3f00000029000e096f0f29011f'
    '0c014000021e0e09550f29001f4f';
const _covNotificationMultiple =
    '09071c020004d229783ea47e0a0104b40c1e0f003f4e0c000000011e09552e4441ac'
    '00002f3c0c1e0e32096f2e8204002f1f0c014000021e09552e91012f1f4f';
const _subscribeCovMultipleError =
    '0e910591000f1e0c000000011e09551f2e910291202f1f';

void main() {
  group('robustness', () {
    final samples = <Uint8List>[
      bytes([0x0C, 0, 0, 0, 5, 0x19, 0x55, 0x3E, 0x44, 0x42, 0x90, 0, 0, 0x3F]),
      encodeReadPropertyMultiple(const [
        BacnetReadAccessSpecification(
          objectIdentifier: BacnetObject(
            type: BacnetObjectType.analogInput,
            instance: 1,
          ),
          properties: [
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.presentValue,
            ),
          ],
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
      for (final hex in [
        vectorOutOfRange,
        vectorChangeOfState,
        vectorBufferReady,
        vectorChangeOfValue,
        vectorAcknowledgeAlarm,
        vectorGetEventInformationAck,
        vectorGetAlarmSummaryAck,
        vectorDestinationAddress + vectorDestinationDevice,
        vectorAddListElement,
        // You-Are and WriteGroup of bacnet-stack
        _youAre,
        _writeGroup,
        _subscribeCovMultiple,
        _covNotificationMultiple,
        _subscribeCovMultipleError,
      ])
        hexBytes(hex),
    ];

    void decodeAll(Uint8List data) {
      for (final decoder in <void Function(Uint8List)>[
        decodeReadPropertyAck,
        decodeReadPropertyMultipleAck,
        decodeReadRangeAck,
        decodeCovNotification,
        decodeComplexError,
        decodeApplicationData,
        decodeEventNotification,
        decodeGetEventInformationAck,
        decodeGetAlarmSummaryAck,
        decodeAcknowledgeAlarm,
        decodeListElements,
        decodeAtomicWriteFile,
        decodeAtomicReadFileAck,
        decodeWhoAmI,
        decodeYouAre,
        decodeWriteGroup,
        decodeSubscribeCovPropertyMultiple,
        decodeCovNotificationMultiple,
        (data) => decodeComplexError(
          data,
          service: BacnetConfirmedService.subscribeCovPropertyMultiple,
        ),
        (data) => BacnetDestination.listFromValue(decodeApplicationData(data)),
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
      for (var i = 0; i < 50000; i++) {
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
