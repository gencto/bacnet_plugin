import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BacnetObject', () {
    test('creates object with required fields', () {
      const obj = BacnetObject(type: BacnetObjectType.analogInput, instance: 1);

      expect(obj.type, equals(BacnetObjectType.analogInput));
      expect(obj.instance, equals(1));
      expect(obj.properties, isEmpty);
    });

    test('creates object with properties', () {
      const obj = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
        properties: {
          BacnetPropertyId.objectName: 'Test Sensor',
          BacnetPropertyId.presentValue: 22.5,
        },
      );

      expect(obj.properties.length, equals(2));
      expect(obj.name, equals('Test Sensor'));
      expect(obj.presentValue, equals(22.5));
    });

    test('copyWith creates independent copy', () {
      const original = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
      );

      final copy = original.copyWith(instance: 2);

      expect(copy.type, equals(original.type));
      expect(copy.instance, equals(2));
      expect(copy.instance, isNot(equals(original.instance)));
    });

    test('copyWith updates properties', () {
      const original = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
        properties: {BacnetPropertyId.objectName: 'Original'},
      );

      final updated = original.copyWith(
        properties: {BacnetPropertyId.objectName: 'Updated'},
      );

      expect(updated.name, equals('Updated'));
      expect(original.name, equals('Original'));
    });

    test('equality based on type and instance', () {
      const obj1 = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
      );

      const obj2 = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
        properties: {BacnetPropertyId.objectName: 'Different'},
      );

      const obj3 = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 2,
      );

      expect(obj1, equals(obj2)); // Same type and instance
      expect(obj1, isNot(equals(obj3))); // Different instance
    });

    test('hashCode consistent with equality', () {
      const obj1 = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
      );

      const obj2 = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
      );

      expect(obj1.hashCode, equals(obj2.hashCode));
    });

    test('toString includes type and instance', () {
      const obj = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
        properties: {BacnetPropertyId.objectName: 'Test'},
      );

      final str = obj.toString();
      expect(str, contains('0')); // Type value
      expect(str, contains('1')); // Instance value
      expect(str, contains('1')); // Property count
    });

    group('helper getters', () {
      test('name returns object name property', () {
        const obj = BacnetObject(
          type: BacnetObjectType.analogInput,
          instance: 1,
          properties: {BacnetPropertyId.objectName: 'Temperature Sensor'},
        );

        expect(obj.name, equals('Temperature Sensor'));
      });

      test('name returns null when not set', () {
        const obj = BacnetObject(
          type: BacnetObjectType.analogInput,
          instance: 1,
        );

        expect(obj.name, isNull);
      });

      test('presentValue returns property value', () {
        const obj = BacnetObject(
          type: BacnetObjectType.analogInput,
          instance: 1,
          properties: {BacnetPropertyId.presentValue: 22.5},
        );

        expect(obj.presentValue, equals(22.5));
      });

      test('presentValue returns null when not set', () {
        const obj = BacnetObject(
          type: BacnetObjectType.analogInput,
          instance: 1,
        );

        expect(obj.presentValue, isNull);
      });

      test('description returns property value', () {
        const obj = BacnetObject(
          type: BacnetObjectType.analogInput,
          instance: 1,
          properties: {BacnetPropertyId.description: 'Room temperature'},
        );

        expect(obj.description, equals('Room temperature'));
      });

      test('units returns property value', () {
        const obj = BacnetObject(
          type: BacnetObjectType.analogInput,
          instance: 1,
          properties: {BacnetPropertyId.units: 62}, // Celsius
        );

        expect(obj.units, equals(62));
      });

      test('outOfService returns property value', () {
        const obj = BacnetObject(
          type: BacnetObjectType.analogInput,
          instance: 1,
          properties: {BacnetPropertyId.outOfService: true},
        );

        expect(obj.outOfService, isTrue);
      });
    });

    group('JSON serialization', () {
      test('toJson serializes all fields', () {
        const obj = BacnetObject(
          type: BacnetObjectType.analogInput,
          instance: 1,
          properties: {
            BacnetPropertyId.objectName: 'Test',
            BacnetPropertyId.presentValue: 22.5,
          },
        );

        final json = obj.toJson();

        expect(json['type'], equals(0));
        expect(json['instance'], equals(1));
        expect(json['properties'], isA<Map<String, dynamic>>());
        expect(json['properties']['77'], equals('Test'));
        expect(json['properties']['85'], equals(22.5));
      });

      test('fromJson deserializes correctly', () {
        final json = {
          'type': 0,
          'instance': 1,
          'properties': {'77': 'Test Sensor', '85': 22.5},
        };

        final obj = BacnetObject.fromJson(json);

        expect(obj.type, equals(0));
        expect(obj.instance, equals(1));
        expect(obj.name, equals('Test Sensor'));
        expect(obj.presentValue, equals(22.5));
      });

      test('roundtrip serialization preserves data', () {
        const original = BacnetObject(
          type: BacnetObjectType.device,
          instance: 1234,
          properties: {
            BacnetPropertyId.objectName: 'Test Device',
            BacnetPropertyId.description: 'Test Description',
          },
        );

        final json = original.toJson();
        final restored = BacnetObject.fromJson(json);

        expect(restored.type, equals(original.type));
        expect(restored.instance, equals(original.instance));
        expect(restored.name, equals(original.name));
        expect(restored.description, equals(original.description));
      });
    });
  });
}
