import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

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

  group('BacnetEngineeringUnits', () {
    test('constants have correct values', () {
      expect(BacnetEngineeringUnits.degreesCelsius, equals(62));
      expect(BacnetEngineeringUnits.percent, equals(98));
      expect(BacnetEngineeringUnits.noUnits, equals(95));
    });

    test('getName returns human-readable names', () {
      expect(BacnetEngineeringUnits.getName(62), equals('Degrees Celsius'));
      expect(BacnetEngineeringUnits.getName(100000), equals('Units 100000'));
    });
  });

  group('generated tables', () {
    test('cover the standard enumerations', () {
      expect(BacnetObjectType.values, hasLength(greaterThanOrEqualTo(65)));
      expect(BacnetPropertyId.values, hasLength(greaterThanOrEqualTo(500)));
      expect(BacnetErrorCode.values, hasLength(greaterThanOrEqualTo(200)));
      expect(
        BacnetObjectType.getName(BacnetObjectType.networkPort),
        'Network Port',
      );
      expect(
        BacnetPropertyId.getName(BacnetPropertyId.covIncrement),
        'COV Increment',
      );
    });

    test('use the standard ranges only', () {
      expect(BacnetObjectType.values.every((v) => v < 128), isTrue);
      expect(BacnetErrorCode.values.every((v) => v < 256), isTrue);
    });

    test('decode common enumerated property values', () {
      expect(
        BacnetEventState.getName(BacnetEventState.offNormal),
        'Off Normal',
      );
      expect(BacnetReliability.getName(0), 'No Fault Detected');
      expect(BacnetSegmentation.getName(BacnetSegmentation.none), 'None');
      expect(BacnetDeviceStatus.getName(0), 'Operational');
    });
  });

  group('extension types', () {
    test('are ints at runtime', () {
      const int raw = BacnetPropertyId.presentValue;
      expect(raw, 85);
      expect(const BacnetPropertyId(85), BacnetPropertyId.presentValue);
      expect(<int, String>{85: 'pv'}[BacnetPropertyId.presentValue], 'pv');
      expect(BacnetObjectType.analogInput + 1, BacnetObjectType.analogOutput);
    });

    test('expose labels and the known values', () {
      expect(BacnetObjectType.multiStateValue.label, 'Multi-state Value');
      expect(const BacnetObjectType(200).label, 'Unknown (200)');
      expect(BacnetErrorCode.unknownObject.label, 'Unknown Object');
      expect(
        BacnetObjectType.values,
        containsAll([BacnetObjectType.device, BacnetObjectType.networkPort]),
      );
    });

    test('work in switch statements', () {
      String kind(BacnetObjectType type) => switch (type) {
        BacnetObjectType.analogInput ||
        BacnetObjectType.analogOutput ||
        BacnetObjectType.analogValue => 'analog',
        _ => 'other',
      };
      expect(kind(BacnetObjectType.analogValue), 'analog');
      expect(kind(BacnetObjectType.device), 'other');
    });

    test('survive JSON round trips of models', () {
      const object = BacnetObject(
        type: BacnetObjectType.binaryValue,
        instance: 3,
      );
      final copy = BacnetObject.fromJson(object.toJson());
      expect(copy.type, BacnetObjectType.binaryValue);
      final units = BacnetValue.fromJson(
        const BacnetEnumerated(BacnetEngineeringUnits.degreesCelsius).toJson(),
      );
      expect(
        BacnetEngineeringUnits(units.asInt!),
        BacnetEngineeringUnits.degreesCelsius,
      );
    });
  });
}
