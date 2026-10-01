import 'dart:convert';
import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

const _sensor = BacnetObject(type: BacnetObjectType.analogInput, instance: 1);

final _everyDatatype = <BacnetValue>[
  const BacnetNull(),
  const BacnetBoolean(true),
  const BacnetUnsigned(42),
  const BacnetSigned(-7),
  const BacnetReal(21.5),
  const BacnetDouble(1e300),
  BacnetOctetString(Uint8List.fromList([0, 0x7F, 0xFF])),
  const BacnetCharacterString('Температура °C'),
  const BacnetBitString([true, false, true, true]),
  const BacnetEnumerated(3),
  const BacnetDate(year: 2026, month: 10, day: 1, weekday: 4),
  const BacnetDate(),
  const BacnetTime(hour: 13, minute: 5, second: 59, hundredths: 99),
  _sensor,
  const BacnetList([BacnetReal(1), BacnetNull()]),
  const BacnetList([]),
  BacnetConstructedValue(0, [
    const BacnetDate(year: 2026, month: 1, day: 2),
    BacnetContextValue(1, Uint8List.fromList([1, 2])),
  ]),
];

/// Describes every datatype; fails to compile when one is missing.
String _describe(BacnetValue value) => switch (value) {
  BacnetNull() => 'null',
  BacnetBoolean(:final value) => 'boolean $value',
  BacnetUnsigned(:final value) => 'unsigned $value',
  BacnetSigned(:final value) => 'signed $value',
  BacnetReal(:final value) => 'real $value',
  BacnetDouble(:final value) => 'double $value',
  BacnetOctetString(:final value) => '${value.length} octets',
  BacnetCharacterString(:final value) => 'text $value',
  BacnetBitString(:final length) => '$length bits',
  BacnetEnumerated(:final value) => 'enumerated $value',
  BacnetDate(:final year) => 'date $year',
  BacnetTime(:final hour) => 'time $hour',
  BacnetObject(:final type, :final instance) => '${type.label} $instance',
  BacnetList(:final length) => 'list of $length',
  BacnetConstructedValue(:final tag) => 'constructed $tag',
  BacnetContextValue(:final tag) => 'context $tag',
};

void main() {
  group('BacnetValue', () {
    test('a switch covers every datatype', () {
      expect(_everyDatatype.map(_describe), [
        'null',
        'boolean true',
        'unsigned 42',
        'signed -7',
        'real 21.5',
        'double 1e+300',
        '3 octets',
        'text Температура °C',
        '4 bits',
        'enumerated 3',
        'date 2026',
        'date null',
        'time 13',
        'Analog Input 1',
        'list of 2',
        'list of 0',
        'constructed 0',
      ]);
    });

    test('values with equal content are equal', () {
      for (final value in _everyDatatype) {
        final copy = BacnetValue.fromJson(value.toJson());
        expect(copy, value, reason: '$value');
        expect(copy.hashCode, value.hashCode, reason: '$value');
      }
      expect(const BacnetUnsigned(1), isNot(const BacnetEnumerated(1)));
      expect(const BacnetReal(1), isNot(const BacnetDouble(1)));
      expect(const BacnetUnsigned(1), isNot(const BacnetSigned(1)));
    });

    test('factories create the datatype classes', () {
      expect(const BacnetValue.nullValue(), isA<BacnetNull>());
      expect(const BacnetValue.real(1), const BacnetReal(1));
      expect(const BacnetValue.enumerated(1), const BacnetEnumerated(1));
      expect(
        const BacnetValue.objectId(
          type: BacnetObjectType.analogInput,
          instance: 1,
        ),
        _sensor,
      );
      expect(
        const BacnetValue.list([BacnetValue.unsigned(1)]),
        const BacnetList([BacnetUnsigned(1)]),
      );
    });

    test('accessors return the Dart value of matching datatypes only', () {
      expect(const BacnetReal(21.5).asDouble, 21.5);
      expect(const BacnetDouble(2).asDouble, 2.0);
      expect(const BacnetUnsigned(3).asDouble, 3.0);
      expect(const BacnetSigned(-3).asDouble, -3.0);
      expect(const BacnetEnumerated(1).asDouble, isNull);
      expect(const BacnetCharacterString('1').asDouble, isNull);

      expect(const BacnetUnsigned(3).asInt, 3);
      expect(const BacnetSigned(-3).asInt, -3);
      expect(const BacnetEnumerated(1).asInt, 1);
      expect(const BacnetReal(1).asInt, isNull);

      expect(const BacnetBoolean(true).asBool, isTrue);
      expect(const BacnetEnumerated(1).asBool, isNull);

      expect(const BacnetCharacterString('Room').asString, 'Room');
      expect(const BacnetNull().asString, isNull);

      expect(
        const BacnetBitString([false, true, false, true]).asStatusFlags,
        const BacnetStatusFlags(fault: true, outOfService: true),
      );
      expect(const BacnetUnsigned(0).asStatusFlags, isNull);
    });

    test('asList treats single values as lists with one element', () {
      expect(const BacnetList([_sensor]).asList, [_sensor]);
      expect(_sensor.asList, [_sensor]);
      expect(const BacnetList([]).asList, isEmpty);
    });

    test('JSON survives encoding to text', () {
      final text = jsonEncode([for (final v in _everyDatatype) v.toJson()]);
      final decoded = [
        for (final json in jsonDecode(text) as List<Object?>)
          BacnetValue.fromJson(json! as Map<String, Object?>),
      ];
      expect(decoded, _everyDatatype);
      expect(const BacnetReal(21.5).toJson(), {
        'datatype': 'real',
        'value': 21.5,
      });
    });

    test('JSON keeps non-finite reals', () {
      for (final value in [double.infinity, double.negativeInfinity]) {
        final json = jsonDecode(jsonEncode(BacnetReal(value).toJson()));
        expect(
          BacnetValue.fromJson(json as Map<String, Object?>),
          BacnetReal(value),
        );
      }
      final nan = BacnetValue.fromJson(
        jsonDecode(jsonEncode(const BacnetReal(double.nan).toJson()))
            as Map<String, Object?>,
      );
      expect(nan.asDouble, isNaN);
    });

    test('malformed JSON throws a FormatException', () {
      for (final json in <Map<String, Object?>>[
        {},
        {'datatype': 'real'},
        {'datatype': 'unsigned', 'value': 'x'},
        {'datatype': 'unsigned', 'value': -1},
        {'datatype': 'enumerated', 'value': -1},
        {'datatype': 'list', 'value': 'x'},
        {
          'datatype': 'list',
          'value': [1],
        },
        {'datatype': 'objectIdentifier', 'type': 'x', 'instance': 1},
        {'datatype': 'imaginary', 'value': 1},
      ]) {
        expect(
          () => BacnetValue.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
    });
  });

  group('BacnetValue.infer', () {
    BacnetValue infer(
      Object? value, [
      BacnetObjectType? type,
      BacnetPropertyId? property,
    ]) => BacnetValue.infer(value, objectType: type, propertyId: property);

    test('present values follow the object type', () {
      const pv = BacnetPropertyId.presentValue;
      expect(
        infer(75, BacnetObjectType.analogOutput, pv),
        const BacnetReal(75),
      );
      expect(
        infer(true, BacnetObjectType.binaryValue, pv),
        const BacnetEnumerated(1),
      );
      expect(
        infer(0, BacnetObjectType.binaryOutput, pv),
        const BacnetEnumerated(0),
      );
      expect(
        infer(3.0, BacnetObjectType.multiStateValue, pv),
        const BacnetUnsigned(3),
      );
      expect(
        infer(3, BacnetObjectType.integerValue, pv),
        const BacnetSigned(3),
      );
      expect(
        infer(5, BacnetObjectType.accumulator, pv),
        const BacnetUnsigned(5),
      );
      expect(
        infer(5, BacnetObjectType.largeAnalogValue, pv),
        const BacnetDouble(5),
      );
      expect(infer(null, BacnetObjectType.analogValue, pv), const BacnetNull());
    });

    test('other properties follow the property or the Dart value', () {
      const av = BacnetObjectType.analogValue;
      expect(
        infer(true, av, BacnetPropertyId.outOfService),
        const BacnetBoolean(true),
      );
      expect(infer(1, av, BacnetPropertyId.covIncrement), const BacnetReal(1));
      expect(
        infer(
          BacnetEngineeringUnits.degreesCelsius,
          av,
          BacnetPropertyId.units,
        ),
        const BacnetEnumerated(62),
      );
      expect(
        infer('Room', av, BacnetPropertyId.description),
        const BacnetCharacterString('Room'),
      );
      expect(infer(-1), const BacnetSigned(-1));
      expect(infer(2.5), const BacnetReal(2.5));
      expect(
        infer([1, 'a']),
        const BacnetList([BacnetUnsigned(1), BacnetCharacterString('a')]),
      );
      expect(infer(const BacnetDouble(1)), const BacnetDouble(1));
      expect(infer(_sensor), _sensor);
    });

    test('rejects Dart types without a BACnet datatype', () {
      expect(() => infer(Object()), throwsArgumentError);
      expect(() => infer(DateTime(2026)), throwsArgumentError);
    });
  });

  group('BacnetObject', () {
    test('equality and hash code use type and instance', () {
      const same = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
      );
      expect(_sensor, same);
      expect(_sensor.hashCode, same.hashCode);
      expect(_sensor, isNot(_sensor.copyWith(instance: 2)));
      expect(
        _sensor,
        isNot(_sensor.copyWith(type: BacnetObjectType.analogOutput)),
      );
      expect({_sensor: 1}[same], 1);
    });

    test('toString names the object type', () {
      expect(_sensor.toString(), 'BacnetObject(Analog Input, 1)');
    });

    test('JSON contains type and instance', () {
      expect(_sensor.toJson(), {
        'datatype': 'objectIdentifier',
        'type': 0,
        'instance': 1,
      });
      expect(BacnetObject.fromJson({'type': 0, 'instance': 1}), _sensor);
      expect(() => BacnetObject.fromJson({'type': 0}), throwsFormatException);
    });
  });

  group('BacnetPropertyResults', () {
    const results = <BacnetPropertyId, BacnetPropertyResult>{
      BacnetPropertyId.presentValue: BacnetReal(21.5),
      BacnetPropertyId.description: BacnetError(
        BacnetErrorClass.property,
        BacnetErrorCode.unknownProperty,
      ),
    };

    test('valueOf and errorOf separate values and errors', () {
      expect(
        results.valueOf(BacnetPropertyId.presentValue),
        const BacnetReal(21.5),
      );
      expect(results.valueOf(BacnetPropertyId.description), isNull);
      expect(results.valueOf(BacnetPropertyId.units), isNull);
      expect(
        results.errorOf(BacnetPropertyId.description)?.errorCode,
        BacnetErrorCode.unknownProperty,
      );
      expect(results.errorOf(BacnetPropertyId.presentValue), isNull);
    });

    test('a switch over a result covers values and errors', () {
      String describe(BacnetPropertyResult? result) => switch (result) {
        BacnetReal(:final value) => 'real $value',
        BacnetValue() => 'other value',
        BacnetError(:final errorCode) => errorCode.label,
        null => 'missing',
      };
      expect(describe(results[BacnetPropertyId.presentValue]), 'real 21.5');
      expect(
        describe(results[BacnetPropertyId.description]),
        'Unknown Property',
      );
      expect(describe(results[BacnetPropertyId.units]), 'missing');
    });
  });

  group('BacnetStatusFlags', () {
    test('converts from and to bit strings and JSON', () {
      const flags = BacnetStatusFlags(inAlarm: true, overridden: true);
      expect(BacnetStatusFlags.fromBitString(flags.toBitString()), flags);
      expect(BacnetStatusFlags.fromJson(flags.toJson()), flags);
      expect(flags.toString(), 'IN_ALARM|OVERRIDDEN');
      expect(const BacnetStatusFlags().isNormal, isTrue);
      expect(const BacnetStatusFlags().toString(), 'OK');
    });
  });
}
