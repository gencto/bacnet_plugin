/// @docImport '../client/bacnet_client.dart';
/// @docImport '../constants/engineering_units.dart';
/// @docImport '../constants/enumerations.dart';
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../constants/errors.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';

/// BACnet application tag numbers (ASHRAE 135, clause 20.2.1.4).
abstract final class BacnetApplicationTag {
  /// Null.
  static const int nullValue = 0;

  /// Boolean.
  static const int boolean = 1;

  /// Unsigned integer.
  static const int unsignedInt = 2;

  /// Signed integer.
  static const int signedInt = 3;

  /// IEEE-754 single precision real.
  static const int real = 4;

  /// IEEE-754 double precision real.
  static const int doubleValue = 5;

  /// Octet string.
  static const int octetString = 6;

  /// Character string.
  static const int characterString = 7;

  /// Bit string.
  static const int bitString = 8;

  /// Enumerated.
  static const int enumerated = 9;

  /// Date.
  static const int date = 10;

  /// Time.
  static const int time = 11;

  /// Object identifier.
  static const int objectIdentifier = 12;
}

/// The result of reading one property: a [BacnetValue], or a [BacnetError]
/// when the device could not return the property.
///
/// [BacnetClient.readMultiple] reports access errors per property with
/// this type. The class is sealed, so a `switch` must handle both cases:
///
/// ```dart
/// switch (properties[BacnetPropertyId.presentValue]) {
///   case BacnetReal(:final value):
///     print('temperature: $value');
///   case BacnetError(:final errorCode):
///     print('not readable: ${errorCode.label}');
///   case null:
///     print('not returned');
///   case BacnetValue():
///     print('unexpected datatype');
/// }
/// ```
@immutable
sealed class BacnetPropertyResult {
  const BacnetPropertyResult();
}

/// A BACnet error: the error class and code a device returned instead of a
/// property value (ASHRAE 135 clause 21, BACnetError).
final class BacnetError extends BacnetPropertyResult {
  /// Creates an error.
  const BacnetError(this.errorClass, this.errorCode);

  /// The error class (device, object, property, ...).
  final BacnetErrorClass errorClass;

  /// The error code within the error class.
  final BacnetErrorCode errorCode;

  @override
  bool operator ==(Object other) =>
      other is BacnetError &&
      other.errorClass == errorClass &&
      other.errorCode == errorCode;

  @override
  int get hashCode => Object.hash(errorClass, errorCode);

  @override
  String toString() => 'BacnetError(${errorClass.label}: ${errorCode.label})';
}

/// A BACnet property value.
///
/// Every BACnet datatype has its own subclass, so the compiler checks how
/// values are used and a `switch` over a value is exhaustive:
///
/// | BACnet datatype | Class | Dart value |
/// | --- | --- | --- |
/// | Null | [BacnetNull] | |
/// | Boolean | [BacnetBoolean] | [bool] |
/// | Unsigned | [BacnetUnsigned] | [int] |
/// | Signed | [BacnetSigned] | [int] |
/// | Real | [BacnetReal] | [double] |
/// | Double | [BacnetDouble] | [double] |
/// | OctetString | [BacnetOctetString] | [Uint8List] |
/// | CharacterString | [BacnetCharacterString] | [String] |
/// | BitString | [BacnetBitString] | `List<bool>` |
/// | Enumerated | [BacnetEnumerated] | [int] |
/// | Date | [BacnetDate] | year, month, day, weekday |
/// | Time | [BacnetTime] | hour, minute, second, hundredths |
/// | ObjectIdentifier | [BacnetObject] | type, instance |
///
/// Arrays and lists are a [BacnetList]; constructed data that the decoder
/// cannot interpret without the property's definition is kept as
/// [BacnetConstructedValue] and [BacnetContextValue].
///
/// Reading:
///
/// ```dart
/// final value = await client.readProperty(1234,
///     BacnetObjectType.analogInput, 1, BacnetPropertyId.presentValue);
/// switch (value) {
///   case BacnetReal(:final value):
///     print('$value °C');
///   case BacnetNull():
///     print('no value');
///   default:
///     print('unexpected $value');
/// }
/// // or, when only one type makes sense (null for any other type):
/// final temperature = value.asDouble;
/// ```
///
/// Writing: the value's class decides the encoded datatype.
///
/// ```dart
/// await client.writeProperty(1234, BacnetObjectType.analogOutput, 1,
///     BacnetPropertyId.presentValue, const BacnetReal(75.5), priority: 8);
/// await client.writeProperty(1234, BacnetObjectType.binaryOutput, 1,
///     BacnetPropertyId.presentValue,
///     const BacnetEnumerated(BacnetBinaryPV.active), priority: 8);
/// await client.writeProperty(1234, BacnetObjectType.analogOutput, 1,
///     BacnetPropertyId.presentValue, const BacnetNull(),
///     priority: 8); // relinquish
/// ```
///
/// [BacnetValue.infer] converts plain Dart values whose datatype is only
/// known at run time (user input, configuration files).
@immutable
sealed class BacnetValue extends BacnetPropertyResult {
  const BacnetValue();

  /// Null (also relinquishes a commandable priority).
  const factory BacnetValue.nullValue() = BacnetNull;

  /// Boolean.
  const factory BacnetValue.boolean(bool value) = BacnetBoolean;

  /// Unsigned integer.
  const factory BacnetValue.unsigned(int value) = BacnetUnsigned;

  /// Signed integer.
  const factory BacnetValue.signed(int value) = BacnetSigned;

  /// Real (single precision).
  const factory BacnetValue.real(double value) = BacnetReal;

  /// Double precision real.
  const factory BacnetValue.doubleValue(double value) = BacnetDouble;

  /// Octet string.
  const factory BacnetValue.octetString(Uint8List value) = BacnetOctetString;

  /// Character string.
  const factory BacnetValue.characterString(String value) =
      BacnetCharacterString;

  /// Bit string, bit 0 first.
  const factory BacnetValue.bitString(List<bool> bits) = BacnetBitString;

  /// Enumerated.
  const factory BacnetValue.enumerated(int value) = BacnetEnumerated;

  /// Date; `null` fields are unspecified.
  const factory BacnetValue.date({
    int? year,
    int? month,
    int? day,
    int? weekday,
  }) = BacnetDate;

  /// Time of day; `null` fields are unspecified.
  const factory BacnetValue.time({
    int? hour,
    int? minute,
    int? second,
    int? hundredths,
  }) = BacnetTime;

  /// Object identifier.
  const factory BacnetValue.objectId({
    required BacnetObjectType type,
    required int instance,
  }) = BacnetObject;

  /// Array or list of values.
  const factory BacnetValue.list(List<BacnetValue> items) = BacnetList;

  /// Converts a plain Dart [value] whose BACnet datatype is not known at
  /// compile time.
  ///
  /// With [objectType] and [propertyId] the datatype of well known
  /// properties is used: REAL for analog present values, ENUMERATED for
  /// binary ones (`true`/`false` or 1/0), UNSIGNED for multi-state ones,
  /// ENUMERATED for units, reliability, event state, ... Otherwise the Dart
  /// type decides: `null` → Null, [bool] → Boolean, [int] → Unsigned
  /// (Signed when negative), [double] → Real, [String] → CharacterString,
  /// [Uint8List] → OctetString, [List] → [BacnetList]. A [BacnetValue] is
  /// returned unchanged.
  ///
  /// Throws an [ArgumentError] for other types.
  factory BacnetValue.infer(
    Object? value, {
    BacnetObjectType? objectType,
    BacnetPropertyId? propertyId,
  }) {
    switch (value) {
      case final BacnetValue value:
        return value;
      case null:
        return const BacnetNull();
      case final Uint8List bytes:
        return BacnetOctetString(bytes);
      case final List<Object?> items:
        return BacnetList([
          for (final item in items)
            BacnetValue.infer(
              item,
              objectType: objectType,
              propertyId: propertyId,
            ),
        ]);
    }
    if (propertyId != null) {
      final known = _inferForProperty(objectType, propertyId, value);
      if (known != null) return known;
    }
    return switch (value) {
      final bool v => BacnetBoolean(v),
      final int v => v < 0 ? BacnetSigned(v) : BacnetUnsigned(v),
      final double v => BacnetReal(v),
      final String v => BacnetCharacterString(v),
      _ => throw ArgumentError.value(
        value,
        'value',
        'no BACnet datatype for ${value.runtimeType}',
      ),
    };
  }

  /// Creates a value from the JSON produced by [toJson].
  ///
  /// Throws a [FormatException] for malformed JSON.
  factory BacnetValue.fromJson(Map<String, Object?> json) {
    final tag = json['tag'];
    final value = switch ((json['datatype'], json['value'])) {
      ('null', _) => const BacnetNull(),
      ('boolean', final bool v) => BacnetBoolean(v),
      ('unsigned', final num v) when v >= 0 => BacnetUnsigned(v.toInt()),
      ('signed', final num v) => BacnetSigned(v.toInt()),
      ('real', final Object v) => BacnetReal(_doubleFromJson(v)),
      ('double', final Object v) => BacnetDouble(_doubleFromJson(v)),
      ('octetString', final String v) => BacnetOctetString(_hexDecode(v)),
      ('characterString', final String v) => BacnetCharacterString(v),
      ('bitString', final String v) => BacnetBitString(
        List.unmodifiable([for (var i = 0; i < v.length; i++) v[i] == '1']),
      ),
      ('enumerated', final num v) when v >= 0 => BacnetEnumerated(v.toInt()),
      ('date', _) => BacnetDate(
        year: _intOrNull(json['year']),
        month: _intOrNull(json['month']),
        day: _intOrNull(json['day']),
        weekday: _intOrNull(json['weekday']),
      ),
      ('time', _) => BacnetTime(
        hour: _intOrNull(json['hour']),
        minute: _intOrNull(json['minute']),
        second: _intOrNull(json['second']),
        hundredths: _intOrNull(json['hundredths']),
      ),
      ('objectIdentifier', _) => BacnetObject.fromJson(json),
      ('list', final List<Object?> v) => BacnetList(_listFromJson(v)),
      ('constructed', final List<Object?> v) when tag is int =>
        BacnetConstructedValue(tag, _listFromJson(v)),
      ('context', final String v) when tag is int => BacnetContextValue(
        tag,
        _hexDecode(v),
      ),
      _ => null,
    };
    return value ?? (throw FormatException('malformed BACnet value', json));
  }

  /// Converts the value to JSON: `{"datatype": "real", "value": 21.5}`.
  Map<String, Object?> toJson();

  /// The value of a [BacnetBoolean], otherwise null.
  bool? get asBool => switch (this) {
    BacnetBoolean(:final value) => value,
    _ => null,
  };

  /// The value of a [BacnetUnsigned], [BacnetSigned] or
  /// [BacnetEnumerated], otherwise null.
  int? get asInt => switch (this) {
    BacnetUnsigned(:final value) ||
    BacnetSigned(:final value) ||
    BacnetEnumerated(:final value) => value,
    _ => null,
  };

  /// The value of a [BacnetReal] or [BacnetDouble], or of a
  /// [BacnetUnsigned] or [BacnetSigned] as double, otherwise null.
  double? get asDouble => switch (this) {
    BacnetReal(:final value) || BacnetDouble(:final value) => value,
    BacnetUnsigned(:final value) ||
    BacnetSigned(:final value) => value.toDouble(),
    _ => null,
  };

  /// The value of a [BacnetCharacterString], otherwise null.
  String? get asString => switch (this) {
    BacnetCharacterString(:final value) => value,
    _ => null,
  };

  /// The status flags of a [BacnetBitString] (Status_Flags), otherwise
  /// null.
  BacnetStatusFlags? get asStatusFlags => switch (this) {
    final BacnetBitString bits => BacnetStatusFlags.fromBitString(bits),
    _ => null,
  };

  /// The elements of a [BacnetList]; any other value as a list with one
  /// element.
  ///
  /// A device returns an array with a single element exactly like a
  /// single value, so use this for arrays and lists (Object_List,
  /// Priority_Array, State_Text, ...).
  List<BacnetValue> get asList => switch (this) {
    BacnetList(:final items) => items,
    _ => [this],
  };
}

/// The Null datatype. Written to a commandable property it relinquishes
/// the priority.
final class BacnetNull extends BacnetValue {
  /// Creates the Null value.
  const BacnetNull();

  @override
  Map<String, Object?> toJson() => const {'datatype': 'null'};

  @override
  bool operator ==(Object other) => other is BacnetNull;

  @override
  int get hashCode => (BacnetNull).hashCode;

  @override
  String toString() => 'BacnetNull()';
}

/// A Boolean.
final class BacnetBoolean extends BacnetValue {
  /// Creates a Boolean.
  const BacnetBoolean(this.value);

  /// The value.
  final bool value;

  @override
  Map<String, Object?> toJson() => {'datatype': 'boolean', 'value': value};

  @override
  bool operator ==(Object other) =>
      other is BacnetBoolean && other.value == value;

  @override
  int get hashCode => Object.hash(BacnetBoolean, value);

  @override
  String toString() => 'BacnetBoolean($value)';
}

/// An Unsigned integer.
final class BacnetUnsigned extends BacnetValue {
  /// Creates an Unsigned.
  const BacnetUnsigned(this.value) : assert(value >= 0);

  /// The value.
  final int value;

  @override
  Map<String, Object?> toJson() => {'datatype': 'unsigned', 'value': value};

  @override
  bool operator ==(Object other) =>
      other is BacnetUnsigned && other.value == value;

  @override
  int get hashCode => Object.hash(BacnetUnsigned, value);

  @override
  String toString() => 'BacnetUnsigned($value)';
}

/// A Signed integer.
final class BacnetSigned extends BacnetValue {
  /// Creates a Signed.
  const BacnetSigned(this.value);

  /// The value.
  final int value;

  @override
  Map<String, Object?> toJson() => {'datatype': 'signed', 'value': value};

  @override
  bool operator ==(Object other) =>
      other is BacnetSigned && other.value == value;

  @override
  int get hashCode => Object.hash(BacnetSigned, value);

  @override
  String toString() => 'BacnetSigned($value)';
}

/// A Real (IEEE-754 single precision).
final class BacnetReal extends BacnetValue {
  /// Creates a Real. The value is rounded to single precision when it is
  /// encoded.
  const BacnetReal(this.value);

  /// The value.
  final double value;

  @override
  Map<String, Object?> toJson() => {
    'datatype': 'real',
    'value': _doubleToJson(value),
  };

  @override
  bool operator ==(Object other) => other is BacnetReal && other.value == value;

  @override
  int get hashCode => Object.hash(BacnetReal, value);

  @override
  String toString() => 'BacnetReal($value)';
}

/// A Double (IEEE-754 double precision).
final class BacnetDouble extends BacnetValue {
  /// Creates a Double.
  const BacnetDouble(this.value);

  /// The value.
  final double value;

  @override
  Map<String, Object?> toJson() => {
    'datatype': 'double',
    'value': _doubleToJson(value),
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetDouble && other.value == value;

  @override
  int get hashCode => Object.hash(BacnetDouble, value);

  @override
  String toString() => 'BacnetDouble($value)';
}

/// An OctetString.
final class BacnetOctetString extends BacnetValue {
  /// Creates an OctetString.
  const BacnetOctetString(this.value);

  /// The octets.
  final Uint8List value;

  @override
  Map<String, Object?> toJson() => {
    'datatype': 'octetString',
    'value': _hexEncode(value),
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetOctetString && _listEquals(other.value, value);

  @override
  int get hashCode => Object.hash(BacnetOctetString, Object.hashAll(value));

  @override
  String toString() => 'BacnetOctetString(${_hexEncode(value)})';
}

/// A CharacterString.
final class BacnetCharacterString extends BacnetValue {
  /// Creates a CharacterString (encoded as UTF-8).
  const BacnetCharacterString(this.value);

  /// The text.
  final String value;

  @override
  Map<String, Object?> toJson() => {
    'datatype': 'characterString',
    'value': value,
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetCharacterString && other.value == value;

  @override
  int get hashCode => Object.hash(BacnetCharacterString, value);

  @override
  String toString() => 'BacnetCharacterString("$value")';
}

/// A BitString (Status_Flags, Event_Enable, ...).
final class BacnetBitString extends BacnetValue {
  /// Creates a bit string from its bits, bit 0 first.
  const BacnetBitString(this.bits);

  /// The bits, bit 0 first.
  final List<bool> bits;

  /// Number of bits.
  int get length => bits.length;

  /// Returns bit [index], or false when out of range.
  bool operator [](int index) =>
      index >= 0 && index < bits.length && bits[index];

  @override
  Map<String, Object?> toJson() => {
    'datatype': 'bitString',
    'value': bits.map((b) => b ? '1' : '0').join(),
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetBitString && _listEquals(other.bits, bits);

  @override
  int get hashCode => Object.hash(BacnetBitString, Object.hashAll(bits));

  @override
  String toString() =>
      'BacnetBitString(${bits.map((b) => b ? '1' : '0').join()})';
}

/// An Enumerated value.
///
/// The meaning depends on the property, e.g. [BacnetBinaryPV] for binary
/// present values or [BacnetEngineeringUnits] for Units.
final class BacnetEnumerated extends BacnetValue {
  /// Creates an Enumerated value.
  const BacnetEnumerated(this.value) : assert(value >= 0);

  /// The value.
  final int value;

  @override
  Map<String, Object?> toJson() => {'datatype': 'enumerated', 'value': value};

  @override
  bool operator ==(Object other) =>
      other is BacnetEnumerated && other.value == value;

  @override
  int get hashCode => Object.hash(BacnetEnumerated, value);

  @override
  String toString() => 'BacnetEnumerated($value)';
}

/// A Date. `null` fields are unspecified (wildcards).
final class BacnetDate extends BacnetValue {
  /// Creates a date.
  const BacnetDate({this.year, this.month, this.day, this.weekday});

  /// Creates a date from a [DateTime].
  factory BacnetDate.fromDateTime(DateTime value) => BacnetDate(
    year: value.year,
    month: value.month,
    day: value.day,
    weekday: value.weekday,
  );

  /// Year (1900..2154) or null.
  final int? year;

  /// Month (1..12, 13 odd, 14 even) or null.
  final int? month;

  /// Day of month (1..31, 32 last day) or null.
  final int? day;

  /// Day of week (1 = Monday .. 7 = Sunday) or null.
  final int? weekday;

  /// Converts to a [DateTime] when year, month and day are specified.
  DateTime? toDateTime() {
    final y = year, m = month, d = day;
    if (y == null || m == null || d == null || m > 12 || d > 31) return null;
    return DateTime(y, m, d);
  }

  @override
  Map<String, Object?> toJson() => {
    'datatype': 'date',
    'year': year,
    'month': month,
    'day': day,
    'weekday': weekday,
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetDate &&
      other.year == year &&
      other.month == month &&
      other.day == day &&
      other.weekday == weekday;

  @override
  int get hashCode => Object.hash(BacnetDate, year, month, day, weekday);

  @override
  String toString() {
    String f(int? v, int width) =>
        v == null ? '*' * width : v.toString().padLeft(width, '0');
    return 'BacnetDate(${f(year, 4)}-${f(month, 2)}-${f(day, 2)})';
  }
}

/// A Time of day. `null` fields are unspecified (wildcards).
final class BacnetTime extends BacnetValue {
  /// Creates a time.
  const BacnetTime({this.hour, this.minute, this.second, this.hundredths});

  /// Creates a time from a [DateTime].
  factory BacnetTime.fromDateTime(DateTime value) => BacnetTime(
    hour: value.hour,
    minute: value.minute,
    second: value.second,
    hundredths: value.millisecond ~/ 10,
  );

  /// Hour (0..23) or null.
  final int? hour;

  /// Minute (0..59) or null.
  final int? minute;

  /// Second (0..59) or null.
  final int? second;

  /// Hundredths of a second (0..99) or null.
  final int? hundredths;

  /// Duration since midnight with unspecified fields treated as zero.
  Duration toDuration() => Duration(
    hours: hour ?? 0,
    minutes: minute ?? 0,
    seconds: second ?? 0,
    milliseconds: (hundredths ?? 0) * 10,
  );

  @override
  Map<String, Object?> toJson() => {
    'datatype': 'time',
    'hour': hour,
    'minute': minute,
    'second': second,
    'hundredths': hundredths,
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetTime &&
      other.hour == hour &&
      other.minute == minute &&
      other.second == second &&
      other.hundredths == hundredths;

  @override
  int get hashCode => Object.hash(BacnetTime, hour, minute, second, hundredths);

  @override
  String toString() {
    String f(int? v) => v == null ? '**' : v.toString().padLeft(2, '0');
    return 'BacnetTime(${f(hour)}:${f(minute)}:${f(second)}.${f(hundredths)})';
  }
}

/// A BACnet object identifier: object type and instance.
///
/// It identifies objects in requests and results, and it is the
/// ObjectIdentifier datatype of property values (Object_List elements,
/// Object_Identifier), so it is a [BacnetValue]. Two identifiers are equal
/// when type and instance are equal.
///
/// ```dart
/// const sensor = BacnetObject(
///   type: BacnetObjectType.analogInput,
///   instance: 1,
/// );
/// ```
final class BacnetObject extends BacnetValue {
  /// Creates an object identifier.
  const BacnetObject({required this.type, required this.instance});

  /// Creates an object identifier from JSON (`type` and `instance`).
  ///
  /// Throws a [FormatException] for malformed JSON.
  factory BacnetObject.fromJson(Map<String, Object?> json) {
    if (json case {'type': final num type, 'instance': final num instance}) {
      return BacnetObject(
        type: BacnetObjectType(type.toInt()),
        instance: instance.toInt(),
      );
    }
    throw FormatException('malformed BACnet object identifier $json');
  }

  /// Largest object instance number (also the "unconfigured" wildcard).
  static const int maxInstance = 4194303;

  /// The object type.
  final BacnetObjectType type;

  /// The instance number, unique per object type within a device.
  final int instance;

  /// Creates a copy with the given fields replaced.
  BacnetObject copyWith({BacnetObjectType? type, int? instance}) =>
      BacnetObject(
        type: type ?? this.type,
        instance: instance ?? this.instance,
      );

  @override
  Map<String, Object?> toJson() => {
    'datatype': 'objectIdentifier',
    'type': type as int,
    'instance': instance,
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetObject && other.type == type && other.instance == instance;

  @override
  int get hashCode => Object.hash(type, instance);

  @override
  String toString() => 'BacnetObject(${type.label}, $instance)';
}

/// An array or list of values (Object_List, Priority_Array, State_Text,
/// ...).
final class BacnetList extends BacnetValue {
  /// Creates a list.
  const BacnetList(this.items);

  /// The elements.
  final List<BacnetValue> items;

  /// Number of elements.
  int get length => items.length;

  /// Element [index] (0 based).
  BacnetValue operator [](int index) => items[index];

  @override
  Map<String, Object?> toJson() => {
    'datatype': 'list',
    'value': [for (final item in items) item.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetList && _listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(BacnetList, Object.hashAll(items));

  @override
  String toString() => 'BacnetList($items)';
}

/// Constructed data: the values enclosed in opening/closing tag [tag].
///
/// Complex property values (schedules, BACnetDateTime, log records, ...)
/// are returned in this form; their meaning is defined by the property.
final class BacnetConstructedValue extends BacnetValue {
  /// Creates a constructed value.
  const BacnetConstructedValue(this.tag, this.values);

  /// Context tag number of the opening/closing pair.
  final int tag;

  /// Enclosed values.
  final List<BacnetValue> values;

  @override
  Map<String, Object?> toJson() => {
    'datatype': 'constructed',
    'tag': tag,
    'value': [for (final value in values) value.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetConstructedValue &&
      other.tag == tag &&
      _listEquals(other.values, values);

  @override
  int get hashCode =>
      Object.hash(BacnetConstructedValue, tag, Object.hashAll(values));

  @override
  String toString() => 'BacnetConstructedValue[$tag]$values';
}

/// A context tagged primitive value whose datatype is defined by the
/// enclosing construct; the content octets are kept raw.
final class BacnetContextValue extends BacnetValue {
  /// Creates a context value.
  const BacnetContextValue(this.tag, this.data);

  /// Context tag number.
  final int tag;

  /// Raw content octets.
  final Uint8List data;

  @override
  Map<String, Object?> toJson() => {
    'datatype': 'context',
    'tag': tag,
    'value': _hexEncode(data),
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetContextValue &&
      other.tag == tag &&
      _listEquals(other.data, data);

  @override
  int get hashCode =>
      Object.hash(BacnetContextValue, tag, Object.hashAll(data));

  @override
  String toString() => 'BacnetContextValue[$tag](${_hexEncode(data)})';
}

/// BACnet status flags (in-alarm, fault, overridden, out-of-service), the
/// typed form of a Status_Flags [BacnetBitString].
@immutable
class BacnetStatusFlags {
  /// Creates status flags.
  const BacnetStatusFlags({
    this.inAlarm = false,
    this.fault = false,
    this.overridden = false,
    this.outOfService = false,
  });

  /// Creates status flags from a decoded bit string.
  factory BacnetStatusFlags.fromBitString(BacnetBitString bits) =>
      BacnetStatusFlags(
        inAlarm: bits[0],
        fault: bits[1],
        overridden: bits[2],
        outOfService: bits[3],
      );

  /// Creates status flags from JSON produced by [toJson].
  factory BacnetStatusFlags.fromJson(Map<String, Object?> json) =>
      BacnetStatusFlags(
        inAlarm: json['inAlarm'] == true,
        fault: json['fault'] == true,
        overridden: json['overridden'] == true,
        outOfService: json['outOfService'] == true,
      );

  /// IN_ALARM flag.
  final bool inAlarm;

  /// FAULT flag.
  final bool fault;

  /// OVERRIDDEN flag.
  final bool overridden;

  /// OUT_OF_SERVICE flag.
  final bool outOfService;

  /// True when no flag is set.
  bool get isNormal => !inAlarm && !fault && !overridden && !outOfService;

  /// The flags as bit string (for writes and COV values).
  BacnetBitString toBitString() =>
      BacnetBitString([inAlarm, fault, overridden, outOfService]);

  /// Converts the flags to JSON.
  Map<String, Object?> toJson() => {
    'inAlarm': inAlarm,
    'fault': fault,
    'overridden': overridden,
    'outOfService': outOfService,
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetStatusFlags &&
      other.inAlarm == inAlarm &&
      other.fault == fault &&
      other.overridden == overridden &&
      other.outOfService == outOfService;

  @override
  int get hashCode => Object.hash(inAlarm, fault, overridden, outOfService);

  @override
  String toString() {
    if (isNormal) return 'OK';
    return [
      if (inAlarm) 'IN_ALARM',
      if (fault) 'FAULT',
      if (overridden) 'OVERRIDDEN',
      if (outOfService) 'OUT_OF_SERVICE',
    ].join('|');
  }
}

/// Typed access to the properties of one object returned by
/// [BacnetClient.readMultiple].
extension BacnetPropertyResults on Map<BacnetPropertyId, BacnetPropertyResult> {
  /// The value of [property], or null when the device returned an error or
  /// left the property out.
  BacnetValue? valueOf(BacnetPropertyId property) => switch (this[property]) {
    final BacnetValue value => value,
    _ => null,
  };

  /// The error returned for [property], or null.
  BacnetError? errorOf(BacnetPropertyId property) => switch (this[property]) {
    final BacnetError error => error,
    _ => null,
  };
}

// ---- datatype inference ----------------------------------------------------

const _realProperties = <int>{
  BacnetPropertyId.covIncrement,
  BacnetPropertyId.deadband,
  BacnetPropertyId.highLimit,
  BacnetPropertyId.lowLimit,
  BacnetPropertyId.maxPresValue,
  BacnetPropertyId.minPresValue,
  BacnetPropertyId.resolution,
};

const _enumeratedProperties = <int>{
  BacnetPropertyId.units,
  BacnetPropertyId.polarity,
  BacnetPropertyId.reliability,
  BacnetPropertyId.eventState,
  BacnetPropertyId.notifyType,
  BacnetPropertyId.systemStatus,
  BacnetPropertyId.segmentationSupported,
  BacnetPropertyId.objectType,
};

/// The datatype of [value] written to a well known property, or null.
BacnetValue? _inferForProperty(
  BacnetObjectType? objectType,
  BacnetPropertyId propertyId,
  Object value,
) {
  final integer = switch (value) {
    final int v => v,
    final double v when v.isFinite && v == v.truncateToDouble() => v.toInt(),
    _ => null,
  };
  if (objectType != null &&
      (propertyId == BacnetPropertyId.presentValue ||
          propertyId == BacnetPropertyId.relinquishDefault ||
          propertyId == BacnetPropertyId.feedbackValue)) {
    switch (objectType) {
      case BacnetObjectType.analogInput:
      case BacnetObjectType.analogOutput:
      case BacnetObjectType.analogValue:
      case BacnetObjectType.loop:
      case BacnetObjectType.lightingOutput:
      case BacnetObjectType.pulseConverter:
        if (value is num) return BacnetReal(value.toDouble());
      case BacnetObjectType.binaryInput:
      case BacnetObjectType.binaryOutput:
      case BacnetObjectType.binaryValue:
      case BacnetObjectType.binaryLightingOutput:
        if (value is bool) return BacnetEnumerated(value ? 1 : 0);
        if (integer != null && integer >= 0) return BacnetEnumerated(integer);
      case BacnetObjectType.multiStateInput:
      case BacnetObjectType.multiStateOutput:
      case BacnetObjectType.multiStateValue:
      case BacnetObjectType.positiveIntegerValue:
      case BacnetObjectType.accumulator:
        if (integer != null && integer >= 0) return BacnetUnsigned(integer);
      case BacnetObjectType.integerValue:
        if (integer != null) return BacnetSigned(integer);
      case BacnetObjectType.largeAnalogValue:
        if (value is num) return BacnetDouble(value.toDouble());
    }
  }
  if (value is num && _realProperties.contains(propertyId)) {
    return BacnetReal(value.toDouble());
  }
  if (_enumeratedProperties.contains(propertyId)) {
    if (value is bool) return BacnetEnumerated(value ? 1 : 0);
    if (integer != null && integer >= 0) return BacnetEnumerated(integer);
  }
  return null;
}

// ---- helpers -----------------------------------------------------------------

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _hexEncode(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexDecode(String hex) {
  if (hex.length.isOdd) throw FormatException('odd hex string length', hex);
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// JSON has no NaN or infinity: they are written as strings.
Object _doubleToJson(double value) => value.isFinite ? value : value.toString();

double _doubleFromJson(Object value) => switch (value) {
  final num v => v.toDouble(),
  final String v => double.parse(v),
  _ => throw FormatException('expected a number', value),
};

int? _intOrNull(Object? value) => switch (value) {
  final num v => v.toInt(),
  _ => null,
};

List<BacnetValue> _listFromJson(List<Object?> items) => [
  for (final item in items)
    switch (item) {
      final Map<String, Object?> json => BacnetValue.fromJson(json),
      _ => throw FormatException('malformed BACnet value', item),
    },
];
