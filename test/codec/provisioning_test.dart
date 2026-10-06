import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/requests.dart';
import 'package:bacnet_plugin/src/codec/responses.dart';
import 'package:test/test.dart';

import '../support/alarm_vectors.dart' show hexBytes;

// Reference encodings produced by the encoders of bacnet-stack
// (who_am_i_request_encode, you_are_request_encode and
// bacnet_write_group_service_request_encode).
const _identity =
    '220104751000526f6f6d20436f6e74726f6c6c6572750800534e2d30303432';
const _whoAmI = _identity;
const _youAre = '${_identity}c4020004d26506c0a80114bac0';
const _youAreNoMac = '${_identity}c4020004d2';
const _youAreNoDevice = '${_identity}6506c0a80114bac0';
const _writeGroup =
    '091719082e09012e44429700002f090219042e21032f09032e002f09042e112f2f3901';
const _writeGroupSimple = '091719082e09012e44429700002f2f';

const _mac = [192, 168, 1, 20, 0xBA, 0xC0];

String _hex(Uint8List data) =>
    data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('Who-Am-I', () {
    test('encodes like bacnet-stack', () {
      expect(
        _hex(
          encodeWhoAmI(
            vendorId: 260,
            modelName: 'Room Controller',
            serialNumber: 'SN-0042',
          ),
        ),
        _whoAmI,
      );
    });

    test('decodes the bacnet-stack encoding', () {
      expect(decodeWhoAmI(hexBytes(_whoAmI)), (
        vendorId: 260,
        modelName: 'Room Controller',
        serialNumber: 'SN-0042',
      ));
    });

    test('rejects malformed requests', () {
      expect(
        () => decodeWhoAmI(hexBytes('2201047510')),
        throwsA(isA<BacnetDecodeException>()),
      );
      // vendor identifier as a real
      expect(
        () => decodeWhoAmI(hexBytes('4442970000')),
        throwsA(isA<BacnetDecodeException>()),
      );
      expect(
        () => encodeWhoAmI(vendorId: 0x10000, modelName: '', serialNumber: ''),
        throwsRangeError,
      );
    });
  });

  group('You-Are', () {
    YouAreData decode(String hex) => decodeYouAre(hexBytes(hex));

    test('encodes like bacnet-stack', () {
      String encode({int? deviceId, List<int>? macAddress}) => _hex(
        encodeYouAre(
          vendorId: 260,
          modelName: 'Room Controller',
          serialNumber: 'SN-0042',
          deviceId: deviceId,
          macAddress: macAddress,
        ),
      );
      expect(encode(deviceId: 1234, macAddress: _mac), _youAre);
      expect(encode(deviceId: 1234), _youAreNoMac);
      expect(encode(macAddress: _mac), _youAreNoDevice);
      expect(encode, throwsArgumentError);
    });

    test('decodes the bacnet-stack encodings', () {
      final full = decode(_youAre);
      expect(full.vendorId, 260);
      expect(full.modelName, 'Room Controller');
      expect(full.serialNumber, 'SN-0042');
      expect(full.deviceId, 1234);
      expect(full.macAddress, _mac);

      expect(decode(_youAreNoMac).deviceId, 1234);
      expect(decode(_youAreNoMac).macAddress, isNull);
      expect(decode(_youAreNoDevice).deviceId, isNull);
      expect(decode(_youAreNoDevice).macAddress, _mac);
    });

    test('rejects requests without device or MAC', () {
      expect(() => decode(_identity), throwsA(isA<BacnetDecodeException>()));
      // an Analog Input instead of the Device
      expect(
        () => decode('${_identity}c4000004d2'),
        throwsA(isA<BacnetDecodeException>()),
      );
    });

    test('events tell whether they address a device', () {
      const event = YouAreEvent(
        vendorId: 260,
        modelName: 'Room Controller',
        serialNumber: 'SN-0042',
        deviceId: 1234,
      );
      expect(
        event.addresses(
          vendorId: 260,
          modelName: 'Room Controller',
          serialNumber: 'SN-0042',
        ),
        isTrue,
      );
      expect(
        event.addresses(
          vendorId: 260,
          modelName: 'Room Controller',
          serialNumber: 'SN-0043',
        ),
        isFalse,
      );
    });
  });

  group('WriteGroup', () {
    final changes = [
      BacnetGroupChannelValue(1, const BacnetReal(75.5)),
      BacnetGroupChannelValue(
        2,
        const BacnetUnsigned(3),
        overridingPriority: 4,
      ),
      BacnetGroupChannelValue(3, const BacnetNull()),
      BacnetGroupChannelValue(4, const BacnetBoolean(true)),
    ];

    test('encodes like bacnet-stack', () {
      expect(
        _hex(
          encodeWriteGroup(23, changes, writePriority: 8, inhibitDelay: true),
        ),
        _writeGroup,
      );
      expect(
        _hex(encodeWriteGroup(23, changes.sublist(0, 1), writePriority: 8)),
        _writeGroupSimple,
      );
    });

    test('decodes the bacnet-stack encodings', () {
      final full = decodeWriteGroup(hexBytes(_writeGroup));
      expect(full.groupNumber, 23);
      expect(full.writePriority, 8);
      expect(full.changes, changes);
      expect(full.inhibitDelay, isTrue);

      final simple = decodeWriteGroup(hexBytes(_writeGroupSimple));
      expect(simple.changes, changes.sublist(0, 1));
      expect(simple.inhibitDelay, isNull);
    });

    test('rejects malformed requests', () {
      // write priority 0
      expect(
        () => decodeWriteGroup(hexBytes('091719002e2f')),
        throwsA(isA<BacnetDecodeException>()),
      );
      // two values for one channel
      expect(
        () => decodeWriteGroup(
          hexBytes('091719082e09012e21012102 2f2f'.replaceAll(' ', '')),
        ),
        throwsA(isA<BacnetDecodeException>()),
      );
      // missing closing tag
      expect(
        () => decodeWriteGroup(
          hexBytes('091719082e09012e2101 2f'.replaceAll(' ', '')),
        ),
        throwsA(isA<BacnetDecodeException>()),
      );
      expect(() => encodeWriteGroup(0, changes), throwsRangeError);
      expect(
        () => encodeWriteGroup(1, changes, writePriority: 17),
        throwsRangeError,
      );
      expect(
        () => BacnetGroupChannelValue(0x10000, const BacnetNull()),
        throwsRangeError,
      );
      expect(
        () => BacnetGroupChannelValue(
          1,
          const BacnetNull(),
          overridingPriority: 0,
        ),
        throwsRangeError,
      );
    });
  });
}
