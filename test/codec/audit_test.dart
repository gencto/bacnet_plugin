import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/requests.dart';
import 'package:test/test.dart';

void main() {
  group('encodeAuditLogQuery', () {
    test('encodes the audit log, sequence start and count', () {
      final bytes = encodeAuditLogQuery(
        auditLog: const BacnetObject(
          type: BacnetObjectType.auditLog,
          instance: 1,
        ),
        startAtSequenceNumber: 5,
        requestedCount: 10,
      );
      expect(
        bytes,
        equals([
          // auditLog [0] object-id (type 61 << 22 | instance 1 = 0x0F400001)
          0x0c, 0x0f, 0x40, 0x00, 0x01,
          // startAtSequenceNumber [2] unsigned 5
          0x29, 0x05,
          // requestedCount [3] unsigned 10
          0x39, 0x0a,
        ]),
      );
    });

    test('omits the optional fields when absent', () {
      final bytes = encodeAuditLogQuery(
        auditLog: const BacnetObject(
          type: BacnetObjectType.auditLog,
          instance: 2,
        ),
      );
      expect(bytes, equals([0x0c, 0x0f, 0x40, 0x00, 0x02]));
    });
  });

  group('BacnetAuditOperation', () {
    test('labels the standard operations', () {
      expect(BacnetAuditOperation.write.label, 'write');
      expect(BacnetAuditOperation.create.label, 'create');
      expect(const BacnetAuditOperation(99).label, 'operation 99');
    });
  });
}
