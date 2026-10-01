import 'dart:convert';
import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/requests.dart';
import 'package:bacnet_plugin/src/codec/responses.dart';
import 'package:test/test.dart';

import '../support/alarm_vectors.dart' show hexBytes;

// Reference encodings produced by the encoders of bacnet-stack
// (dcc_service_request_encode, reinitialize_device_request_encode,
// create_object_*, delete_object_service_request_encode, arf_*, awf_*,
// private_transfer_request_encode and ptransfer_error_encode_service).
const _dccDisableInitiation = '093c19022d090066696c6973746572';
const _dccEnable = '1900';
const _reinitWarmStart = '09011d090066696c6973746572';
const _reinitActivateChanges = '0907';
const _createByType =
    '0e09020f1e094d2e750900536574706f696e742f09552e4441ac00002f39081f';
const _createById = '0e1c014000070f';
const _createAck = 'c40080000c';
const _createError = '0e910291280f1902';
const _deleteObject = 'c40080000c';
const _readStream = 'c4028000010e3204002202000f';
const _readRecords = 'c4028000011e310321021f';
const _readStreamAck = '110e320400650568656c6c6f0f';
const _readRecordsAck = '101e310321016261621f';
const _writeStream = 'c4028000020e31ff6506617070656e640f';
const _writeRecord = 'c4028000021e31042101637265631f';
const _writeStreamAck = '0a0800';
const _writeRecordAck = '1904';
const _privateTransfer = '0a010419072e2105443fc000002f';
const _privateTransferError = '0e910591000f1a010429073e2105443fc000003f';

String _hex(Uint8List data) =>
    data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('device management requests', () {
    test('DeviceCommunicationControl', () {
      expect(
        _hex(
          encodeDeviceCommunicationControl(
            BacnetCommunicationState.disableInitiation,
            duration: const Duration(hours: 1),
            password: 'filister',
          ),
        ),
        _dccDisableInitiation,
      );
      expect(
        _hex(encodeDeviceCommunicationControl(BacnetCommunicationState.enable)),
        _dccEnable,
      );
      expect(
        () => encodeDeviceCommunicationControl(
          BacnetCommunicationState.disable,
          duration: const Duration(seconds: 30),
        ),
        throwsArgumentError,
      );
      expect(
        () => encodeDeviceCommunicationControl(
          BacnetCommunicationState.disable,
          duration: const Duration(minutes: 0x10000),
        ),
        throwsArgumentError,
      );
      expect(
        () => encodeDeviceCommunicationControl(
          BacnetCommunicationState.disable,
          password: 'x' * 21,
        ),
        throwsArgumentError,
      );
    });

    test('ReinitializeDevice', () {
      expect(
        _hex(
          encodeReinitializeDevice(
            BacnetReinitializedState.warmStart,
            password: 'filister',
          ),
        ),
        _reinitWarmStart,
      );
      expect(
        _hex(
          encodeReinitializeDevice(BacnetReinitializedState.activateChanges),
        ),
        _reinitActivateChanges,
      );
      expect(
        () => encodeReinitializeDevice(
          BacnetReinitializedState.coldStart,
          password: '',
        ),
        throwsArgumentError,
      );
    });

    test('decode requests the server reports', () {
      final dcc = decodeDeviceCommunicationControl(
        hexBytes(_dccDisableInitiation),
      );
      expect(dcc.state, BacnetCommunicationState.disableInitiation);
      expect(dcc.duration, const Duration(hours: 1));
      expect(dcc.password, 'filister');
      final enable = decodeDeviceCommunicationControl(hexBytes(_dccEnable));
      expect(enable.duration, isNull);
      expect(enable.password, isNull);
      final reinit = decodeReinitializeDevice(hexBytes(_reinitWarmStart));
      expect(reinit.state, BacnetReinitializedState.warmStart);
      expect(reinit.password, 'filister');
      expect(
        decodeReinitializeDevice(hexBytes(_reinitActivateChanges)).password,
        isNull,
      );
    });

    test('CreateObject', () {
      expect(
        _hex(
          encodeCreateObject(
            type: BacnetObjectType.analogValue,
            initialValues: const [
              BacnetPropertyValue(
                propertyIdentifier: BacnetPropertyId.objectName,
                value: BacnetCharacterString('Setpoint'),
              ),
              BacnetPropertyValue(
                propertyIdentifier: BacnetPropertyId.presentValue,
                value: BacnetReal(21.5),
                priority: 8,
              ),
            ],
          ),
        ),
        _createByType,
      );
      expect(
        _hex(
          encodeCreateObject(
            object: const BacnetObject(
              type: BacnetObjectType.binaryValue,
              instance: 7,
            ),
          ),
        ),
        _createById,
      );
      expect(encodeCreateObject, throwsArgumentError);
      expect(
        decodeCreateObjectAck(hexBytes(_createAck)),
        const BacnetObject(type: BacnetObjectType.analogValue, instance: 12),
      );
      expect(
        () => decodeCreateObjectAck(hexBytes('${_createAck}21')),
        throwsA(isA<BacnetDecodeException>()),
      );
    });

    test('CreateObject-Error names the failed initial value', () {
      final error = decodeComplexError(
        hexBytes(_createError),
        service: BacnetConfirmedService.createObject,
      );
      expect(
        error.error,
        const BacnetError(
          BacnetErrorClass.property,
          BacnetErrorCode.writeAccessDenied,
        ),
      );
      expect(error.firstFailedElement, 2);
      // other services do not carry the element number
      expect(
        decodeComplexError(
          hexBytes(_createError),
          service: BacnetConfirmedService.writePropertyMultiple,
        ).firstFailedElement,
        isNull,
      );
    });

    test('DeleteObject', () {
      expect(
        _hex(
          encodeDeleteObject(
            const BacnetObject(
              type: BacnetObjectType.analogValue,
              instance: 12,
            ),
          ),
        ),
        _deleteObject,
      );
    });
  });

  group('files', () {
    test('AtomicReadFile requests', () {
      expect(
        _hex(encodeAtomicReadFile(1, start: 1024, count: 512)),
        _readStream,
      );
      expect(
        _hex(encodeAtomicReadFile(1, start: 3, count: 2, records: true)),
        _readRecords,
      );
    });

    test('AtomicReadFile-ACK', () {
      expect(
        decodeAtomicReadFileAck(hexBytes(_readStreamAck)).chunk,
        BacnetFileChunk(
          start: 1024,
          data: utf8.encode('hello'),
          endOfFile: true,
        ),
      );
      final records = decodeAtomicReadFileAck(hexBytes(_readRecordsAck));
      expect(records.chunk, isNull);
      expect(
        records.records,
        BacnetFileRecords(
          start: 3,
          records: [utf8.encode('ab')],
          endOfFile: false,
        ),
      );
    });

    test('AtomicWriteFile', () {
      expect(
        _hex(encodeAtomicWriteFileStream(2, utf8.encode('append'), start: -1)),
        _writeStream,
      );
      expect(
        _hex(encodeAtomicWriteFileRecords(2, [utf8.encode('rec')], start: 4)),
        _writeRecord,
      );
      expect(decodeAtomicWriteFileAck(hexBytes(_writeStreamAck)), 2048);
      expect(decodeAtomicWriteFileAck(hexBytes(_writeRecordAck)), 4);
    });

    test('AtomicWriteFile requests decode (server side)', () {
      final stream = decodeAtomicWriteFile(hexBytes(_writeStream));
      expect(
        stream.file,
        const BacnetObject(type: BacnetObjectType.file, instance: 2),
      );
      expect(stream.start, -1);
      expect(stream.data, utf8.encode('append'));
      expect(stream.records, isNull);
      final records = decodeAtomicWriteFile(hexBytes(_writeRecord));
      expect(records.start, 4);
      expect(records.data, isNull);
      expect(records.records, [utf8.encode('rec')]);
      for (final hex in [_writeStream, _writeRecord]) {
        final data = hexBytes(hex);
        for (var length = 0; length < data.length; length++) {
          expect(
            () => decodeAtomicWriteFile(Uint8List.sublistView(data, 0, length)),
            throwsA(isA<BacnetDecodeException>()),
            reason: '$hex[:$length]',
          );
        }
      }
    });

    test('truncated answers are rejected', () {
      for (final hex in [_readStreamAck, _readRecordsAck]) {
        final data = hexBytes(hex);
        for (var length = 0; length < data.length; length++) {
          expect(
            () =>
                decodeAtomicReadFileAck(Uint8List.sublistView(data, 0, length)),
            throwsA(isA<BacnetDecodeException>()),
            reason: '$hex[:$length]',
          );
        }
      }
    });
  });

  group('vendor services and messages', () {
    test('PrivateTransfer', () {
      const parameters = BacnetList([BacnetUnsigned(5), BacnetReal(1.5)]);
      expect(
        _hex(encodePrivateTransfer(260, 7, parameters: parameters)),
        _privateTransfer,
      );
      final decoded = decodePrivateTransfer(hexBytes(_privateTransfer));
      expect(decoded.vendorId, 260);
      expect(decoded.serviceNumber, 7);
      expect(decoded.parameters, parameters);
      expect(
        decodeComplexError(
          hexBytes(_privateTransferError),
          service: BacnetConfirmedService.privateTransfer,
        ),
        (
          error: const BacnetError(
            BacnetErrorClass.services,
            BacnetErrorCode.other,
          ),
          firstFailedElement: null,
        ),
      );
    });

    test('TextMessage round trips', () {
      final data = encodeTextMessage(
        4321,
        'Filter change due',
        urgent: true,
        classText: 'maintenance',
      );
      final decoded = decodeTextMessage(data);
      expect(decoded.source.instance, 4321);
      expect(decoded.message, 'Filter change due');
      expect(decoded.urgent, isTrue);
      expect(decoded.classText, 'maintenance');
      expect(
        decodeTextMessage(
          encodeTextMessage(1, 'x', classNumber: 3),
        ).classNumber,
        3,
      );
      expect(
        () => encodeTextMessage(1, 'x', classNumber: 1, classText: 'a'),
        throwsArgumentError,
      );
    });
  });
}
