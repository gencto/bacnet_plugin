import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BacnetPropertyReference', () {
    test('creates with required propertyIdentifier', () {
      const ref = BacnetPropertyReference(
        propertyIdentifier: BacnetPropertyId.presentValue,
      );

      expect(ref.propertyIdentifier, equals(BacnetPropertyId.presentValue));
      expect(ref.propertyArrayIndex, equals(-1));
    });

    test('creates with array index', () {
      const ref = BacnetPropertyReference(
        propertyIdentifier: BacnetPropertyId.objectList,
        propertyArrayIndex: 5,
      );

      expect(ref.propertyIdentifier, equals(BacnetPropertyId.objectList));
      expect(ref.propertyArrayIndex, equals(5));
    });

    test('copyWith updates values', () {
      const original = BacnetPropertyReference(
        propertyIdentifier: BacnetPropertyId.presentValue,
      );

      final updated = original.copyWith(propertyArrayIndex: 3);

      expect(updated.propertyIdentifier, equals(original.propertyIdentifier));
      expect(updated.propertyArrayIndex, equals(3));
    });

    test('equality based on all fields', () {
      const ref1 = BacnetPropertyReference(
        propertyIdentifier: BacnetPropertyId.presentValue,
        propertyArrayIndex: 1,
      );

      const ref2 = BacnetPropertyReference(
        propertyIdentifier: BacnetPropertyId.presentValue,
        propertyArrayIndex: 1,
      );

      const ref3 = BacnetPropertyReference(
        propertyIdentifier: BacnetPropertyId.presentValue,
        propertyArrayIndex: 2,
      );

      expect(ref1, equals(ref2));
      expect(ref1, isNot(equals(ref3)));
    });

    test('toString shows property and array index', () {
      const ref = BacnetPropertyReference(
        propertyIdentifier: BacnetPropertyId.presentValue,
        propertyArrayIndex: 5,
      );

      final str = ref.toString();
      expect(str, contains('85')); // Present value ID
      expect(str, contains('5')); // Array index
    });

    test('toString omits array index when -1', () {
      const ref = BacnetPropertyReference(
        propertyIdentifier: BacnetPropertyId.presentValue,
      );

      final str = ref.toString();
      expect(str, contains('85'));
      expect(str, isNot(contains('[')));
    });

    group('JSON serialization', () {
      test('toJson serializes all fields', () {
        const ref = BacnetPropertyReference(
          propertyIdentifier: BacnetPropertyId.presentValue,
          propertyArrayIndex: 3,
        );

        final json = ref.toJson();

        expect(json['propertyIdentifier'], equals(85));
        expect(json['propertyArrayIndex'], equals(3));
      });

      test('fromJson deserializes correctly', () {
        final json = <String, dynamic>{
          'propertyIdentifier': 85,
          'propertyArrayIndex': 2,
        };

        final ref = BacnetPropertyReference.fromJson(json);

        expect(ref.propertyIdentifier, equals(85));
        expect(ref.propertyArrayIndex, equals(2));
      });

      test('roundtrip preserves data', () {
        const original = BacnetPropertyReference(
          propertyIdentifier: BacnetPropertyId.objectName,
          propertyArrayIndex: 0,
        );

        final restored = BacnetPropertyReference.fromJson(original.toJson());

        expect(restored, equals(original));
      });
    });
  });

  group('BacnetReadAccessSpecification', () {
    test('creates with object and properties', () {
      const obj = BacnetObject(type: BacnetObjectType.analogInput, instance: 1);

      const spec = BacnetReadAccessSpecification(
        objectIdentifier: obj,
        properties: [
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.presentValue,
          ),
        ],
      );

      expect(spec.objectIdentifier, equals(obj));
      expect(spec.properties.length, equals(1));
    });

    test('copyWith updates values', () {
      const obj = BacnetObject(type: 0, instance: 1);
      const original = BacnetReadAccessSpecification(
        objectIdentifier: obj,
        properties: [],
      );

      final newProps = [
        const BacnetPropertyReference(
          propertyIdentifier: BacnetPropertyId.presentValue,
        ),
      ];
      final updated = original.copyWith(properties: newProps);

      expect(updated.objectIdentifier, equals(obj));
      expect(updated.properties, equals(newProps));
    });

    test('equality based on object identifier', () {
      const obj1 = BacnetObject(type: 0, instance: 1);
      const obj2 = BacnetObject(type: 0, instance: 1);
      const obj3 = BacnetObject(type: 0, instance: 2);

      const spec1 = BacnetReadAccessSpecification(
        objectIdentifier: obj1,
        properties: [],
      );

      const spec2 = BacnetReadAccessSpecification(
        objectIdentifier: obj2,
        properties: [],
      );

      const spec3 = BacnetReadAccessSpecification(
        objectIdentifier: obj3,
        properties: [],
      );

      expect(spec1, equals(spec2));
      expect(spec1, isNot(equals(spec3)));
    });

    group('JSON serialization', () {
      test('toJson serializes nested objects', () {
        const obj = BacnetObject(type: 0, instance: 1);
        const spec = BacnetReadAccessSpecification(
          objectIdentifier: obj,
          properties: [
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.presentValue,
            ),
          ],
        );

        final json = spec.toJson();

        expect(json['objectIdentifier'], isA<Map<String, dynamic>>());
        expect(json['properties'], isA<List<dynamic>>());
        expect((json['properties'] as List<dynamic>).length, equals(1));
      });

      test('roundtrip preserves data', () {
        const original = BacnetReadAccessSpecification(
          objectIdentifier: BacnetObject(type: 0, instance: 1),
          properties: [
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.presentValue,
            ),
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.objectName,
            ),
          ],
        );

        final json = original.toJson();
        final restored = BacnetReadAccessSpecification.fromJson(json);

        expect(
          restored.objectIdentifier.type,
          equals(original.objectIdentifier.type),
        );
        expect(
          restored.objectIdentifier.instance,
          equals(original.objectIdentifier.instance),
        );
        expect(restored.properties.length, equals(2));
      });
    });
  });
}
