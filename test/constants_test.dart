import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BacnetObjectType', () {
    test('constants have correct values', () {
      expect(BacnetObjectType.analogInput, equals(0));
      expect(BacnetObjectType.analogOutput, equals(1));
      expect(BacnetObjectType.device, equals(8));
      expect(BacnetObjectType.trendLog, equals(20));
    });

    test('getName returns human-readable names', () {
      expect(BacnetObjectType.getName(0), equals('Analog Input'));
      expect(BacnetObjectType.getName(1), equals('Analog Output'));
      expect(BacnetObjectType.getName(8), equals('Device'));
    });

    test('getName returns unknown for invalid types', () {
      expect(BacnetObjectType.getName(999), equals('Unknown (999)'));
    });
  });

  group('BacnetPropertyId', () {
    test('constants have correct values', () {
      expect(BacnetPropertyId.objectName, equals(77));
      expect(BacnetPropertyId.presentValue, equals(85));
      expect(BacnetPropertyId.description, equals(28));
    });

    test('getName returns human-readable names', () {
      expect(BacnetPropertyId.getName(77), equals('Object Name'));
      expect(BacnetPropertyId.getName(85), equals('Present Value'));
      expect(BacnetPropertyId.getName(28), equals('Description'));
    });

    test('getName returns unknown for invalid IDs', () {
      expect(BacnetPropertyId.getName(9999), equals('Property 9999'));
    });
  });

  group('BacnetErrorClass', () {
    test('constants have correct values', () {
      expect(BacnetErrorClass.device, equals(0));
      expect(BacnetErrorClass.object, equals(1));
      expect(BacnetErrorClass.property, equals(2));
    });

    test('getName returns human-readable names', () {
      expect(BacnetErrorClass.getName(0), equals('Device'));
      expect(BacnetErrorClass.getName(1), equals('Object'));
      expect(BacnetErrorClass.getName(2), equals('Property'));
    });
  });

  group('BacnetErrorCode', () {
    test('constants have correct values', () {
      expect(BacnetErrorCode.unknownObject, equals(31));
      expect(BacnetErrorCode.unknownProperty, equals(32));
      expect(BacnetErrorCode.timeout, equals(30));
    });

    test('getName returns human-readable names', () {
      expect(BacnetErrorCode.getName(31), contains('Unknown Object'));
      expect(BacnetErrorCode.getName(32), contains('Unknown Property'));
    });
  });
}
