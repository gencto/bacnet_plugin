import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../models/bacnet_object.dart';

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

/// A BACnet bit string (status flags, event enable, ...).
@immutable
class BacnetBitString {
  /// Creates a bit string from its bits (bit 0 first).
  const BacnetBitString(this.bits);

  /// The bits, bit 0 first.
  final List<bool> bits;

  /// Number of bits.
  int get length => bits.length;

  /// Returns bit [index] or false when out of range.
  bool operator [](int index) =>
      index >= 0 && index < bits.length && bits[index];

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! BacnetBitString || other.bits.length != bits.length) {
      return false;
    }
    for (var i = 0; i < bits.length; i++) {
      if (bits[i] != other.bits[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(bits);

  @override
  String toString() => '{${bits.map((b) => b ? '1' : '0').join(',')}}';
}

/// BACnet status flags (in-alarm, fault, overridden, out-of-service).
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

/// A BACnet date. `null` fields are unspecified (wildcards).
@immutable
class BacnetDate {
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
  bool operator ==(Object other) =>
      other is BacnetDate &&
      other.year == year &&
      other.month == month &&
      other.day == day &&
      other.weekday == weekday;

  @override
  int get hashCode => Object.hash(year, month, day, weekday);

  @override
  String toString() {
    String f(int? v, int width) =>
        v == null ? '*' * width : v.toString().padLeft(width, '0');
    return '${f(year, 4)}-${f(month, 2)}-${f(day, 2)}';
  }
}

/// A BACnet time of day. `null` fields are unspecified (wildcards).
@immutable
class BacnetTime {
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
  bool operator ==(Object other) =>
      other is BacnetTime &&
      other.hour == hour &&
      other.minute == minute &&
      other.second == second &&
      other.hundredths == hundredths;

  @override
  int get hashCode => Object.hash(hour, minute, second, hundredths);

  @override
  String toString() {
    String f(int? v) => v == null ? '**' : v.toString().padLeft(2, '0');
    return '${f(hour)}:${f(minute)}:${f(second)}.${f(hundredths)}';
  }
}

/// A context tagged primitive value whose type is defined by the enclosing
/// construct (kept raw because the decoder cannot know the type).
@immutable
class BacnetContextValue {
  /// Creates a context value.
  const BacnetContextValue(this.tag, this.data);

  /// Context tag number.
  final int tag;

  /// Raw content octets.
  final Uint8List data;

  @override
  bool operator ==(Object other) {
    if (other is! BacnetContextValue || other.tag != tag) return false;
    if (other.data.length != data.length) return false;
    for (var i = 0; i < data.length; i++) {
      if (other.data[i] != data[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(tag, Object.hashAll(data));

  @override
  String toString() => 'Context[$tag](${data.length} bytes)';
}

/// A constructed value: the values enclosed in opening/closing tag [tag].
@immutable
class BacnetConstructedValue {
  /// Creates a constructed value.
  const BacnetConstructedValue(this.tag, this.values);

  /// Context tag number of the opening/closing pair.
  final int tag;

  /// Enclosed values.
  final List<Object?> values;

  @override
  String toString() => 'Constructed[$tag]$values';
}

/// An explicitly typed value for writes.
///
/// Use it when the BACnet datatype cannot be inferred from the Dart value,
/// for example to write an enumerated value or to relinquish a priority:
///
/// ```dart
/// await client.writeProperty(1, BacnetObjectType.binaryOutput, 1,
///     BacnetPropertyId.presentValue, const BacnetValue.enumerated(1),
///     priority: 8);
/// await client.writeProperty(1, BacnetObjectType.analogOutput, 1,
///     BacnetPropertyId.presentValue, const BacnetValue.nullValue(),
///     priority: 8); // relinquish
/// ```
@immutable
class BacnetValue {
  /// Creates a value with an explicit application [tag].
  const BacnetValue(this.tag, this.value);

  /// NULL (used to relinquish a commandable priority).
  const BacnetValue.nullValue()
    : tag = BacnetApplicationTag.nullValue,
      value = null;

  /// BOOLEAN.
  const BacnetValue.boolean(bool this.value)
    : tag = BacnetApplicationTag.boolean;

  /// Unsigned integer.
  const BacnetValue.unsigned(int this.value)
    : tag = BacnetApplicationTag.unsignedInt;

  /// Signed integer.
  const BacnetValue.signed(int this.value)
    : tag = BacnetApplicationTag.signedInt;

  /// REAL (single precision).
  const BacnetValue.real(double this.value) : tag = BacnetApplicationTag.real;

  /// Double precision real.
  const BacnetValue.doubleValue(double this.value)
    : tag = BacnetApplicationTag.doubleValue;

  /// Character string (UTF-8).
  const BacnetValue.characterString(String this.value)
    : tag = BacnetApplicationTag.characterString;

  /// ENUMERATED.
  const BacnetValue.enumerated(int this.value)
    : tag = BacnetApplicationTag.enumerated;

  /// Object identifier.
  const BacnetValue.objectId(BacnetObject this.value)
    : tag = BacnetApplicationTag.objectIdentifier;

  /// Application tag (see [BacnetApplicationTag]).
  final int tag;

  /// Dart value.
  final Object? value;

  @override
  bool operator ==(Object other) =>
      other is BacnetValue && other.tag == tag && other.value == value;

  @override
  int get hashCode => Object.hash(tag, value);

  @override
  String toString() => 'BacnetValue(tag: $tag, value: $value)';
}
