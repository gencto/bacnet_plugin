/// @docImport '../client/bacnet_client.dart';
/// @docImport 'bacnet_property.dart';
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../codec/value_encoding.dart';
import '../constants/enumerations.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import 'bacnet_value.dart';
import 'construct_support.dart';

// Typed forms of the constructed datatypes of ASHRAE 135 clause 21 that
// schedules, calendars, trend logs and event reporting use. A read returns
// them as generic BacnetValues (BacnetConstructedValue and
// BacnetContextValue, since the decoder cannot know the construct);
// `fromValue` interprets such a value, `toValue` builds the value to write.
// The typed properties of BacnetProperties do both automatically.

/// A date and a time of day (BACnetDateTime), e.g. Start_Time of a Trend
/// Log.
@immutable
final class BacnetDateTime {
  /// Creates a date and time.
  const BacnetDateTime(this.date, this.time);

  /// Creates a date and time from a [DateTime].
  factory BacnetDateTime.fromDateTime(DateTime value) => BacnetDateTime(
    BacnetDate.fromDateTime(value),
    BacnetTime.fromDateTime(value),
  );

  /// Interprets a read value. Throws a [BacnetDecodeException] if it is
  /// not a date followed by a time.
  factory BacnetDateTime.fromValue(BacnetValue value) =>
      _fromItems(_items(value), value);

  static BacnetDateTime _fromItems(List<BacnetValue> items, Object source) {
    if (items case [final BacnetDate date, final BacnetTime time]) {
      return BacnetDateTime(date, time);
    }
    throw malformedConstruct('BACnetDateTime', source);
  }

  /// The date.
  final BacnetDate date;

  /// The time of day.
  final BacnetTime time;

  /// The value to write.
  BacnetValue toValue() => BacnetList([date, time]);

  /// Converts to a [DateTime] when the date is fully specified.
  DateTime? toDateTime() => date.toDateTime()?.add(time.toDuration());

  @override
  bool operator ==(Object other) =>
      other is BacnetDateTime && other.date == date && other.time == time;

  @override
  int get hashCode => Object.hash(date, time);

  @override
  String toString() => 'BacnetDateTime($date $time)';
}

/// When something happened (BACnetTimeStamp): a time of day, a sequence
/// number or a date and time. Event_Time_Stamps holds three of them.
@immutable
sealed class BacnetTimeStamp {
  const BacnetTimeStamp();

  /// Interprets a read value. Throws a [BacnetDecodeException] for
  /// anything else.
  factory BacnetTimeStamp.fromValue(BacnetValue value) => switch (value) {
    BacnetContextValue(tag: 0, :final data) => BacnetTimeStampTime(
      constructPrimitive<BacnetTime>(data, BacnetApplicationTag.time, value),
    ),
    BacnetContextValue(tag: 1, :final data) => BacnetTimeStampSequence(
      constructPrimitive<BacnetUnsigned>(
        data,
        BacnetApplicationTag.unsignedInt,
        value,
      ).value,
    ),
    BacnetConstructedValue(tag: 2, :final values) => BacnetTimeStampDateTime(
      BacnetDateTime._fromItems(values, value),
    ),
    _ => throw malformedConstruct('BACnetTimeStamp', value),
  };

  /// Interprets a list of time stamps (Event_Time_Stamps).
  static List<BacnetTimeStamp> listFromValue(BacnetValue value) =>
      List.unmodifiable(_items(value).map(BacnetTimeStamp.fromValue));

  /// The value to write.
  BacnetValue toValue();
}

/// A time stamp with a time of day.
final class BacnetTimeStampTime extends BacnetTimeStamp {
  /// Creates the time stamp.
  const BacnetTimeStampTime(this.time);

  /// The time of day.
  final BacnetTime time;

  @override
  BacnetValue toValue() => contextValue(0, time);

  @override
  bool operator ==(Object other) =>
      other is BacnetTimeStampTime && other.time == time;

  @override
  int get hashCode => time.hashCode;

  @override
  String toString() => 'BacnetTimeStampTime($time)';
}

/// A time stamp with a sequence number.
final class BacnetTimeStampSequence extends BacnetTimeStamp {
  /// Creates the time stamp.
  const BacnetTimeStampSequence(this.sequenceNumber);

  /// The sequence number.
  final int sequenceNumber;

  @override
  BacnetValue toValue() => contextValue(1, BacnetUnsigned(sequenceNumber));

  @override
  bool operator ==(Object other) =>
      other is BacnetTimeStampSequence &&
      other.sequenceNumber == sequenceNumber;

  @override
  int get hashCode => sequenceNumber.hashCode;

  @override
  String toString() => 'BacnetTimeStampSequence($sequenceNumber)';
}

/// A time stamp with a date and time.
final class BacnetTimeStampDateTime extends BacnetTimeStamp {
  /// Creates the time stamp.
  const BacnetTimeStampDateTime(this.dateTime);

  /// The date and time.
  final BacnetDateTime dateTime;

  @override
  BacnetValue toValue() =>
      BacnetConstructedValue(2, [dateTime.date, dateTime.time]);

  @override
  bool operator ==(Object other) =>
      other is BacnetTimeStampDateTime && other.dateTime == dateTime;

  @override
  int get hashCode => dateTime.hashCode;

  @override
  String toString() => 'BacnetTimeStampDateTime($dateTime)';
}

/// A value scheduled at a time of day (BACnetTimeValue).
@immutable
final class BacnetTimeValue {
  /// Creates a time value.
  const BacnetTimeValue(this.time, this.value);

  /// When the value takes effect.
  final BacnetTime time;

  /// The scheduled value (a primitive value; `BacnetNull` relinquishes).
  final BacnetValue value;

  static List<BacnetTimeValue> _pairs(List<BacnetValue> items, Object source) {
    if (items.length.isOdd) {
      throw malformedConstruct('BACnetTimeValue list', source);
    }
    return List.unmodifiable([
      for (var i = 0; i < items.length; i += 2)
        switch (items[i]) {
          final BacnetTime time => BacnetTimeValue(time, items[i + 1]),
          _ => throw malformedConstruct('BACnetTimeValue', source),
        },
    ]);
  }

  static List<BacnetValue> _flatten(List<BacnetTimeValue> values) => [
    for (final entry in values) ...[entry.time, entry.value],
  ];

  @override
  bool operator ==(Object other) =>
      other is BacnetTimeValue && other.time == time && other.value == value;

  @override
  int get hashCode => Object.hash(time, value);

  @override
  String toString() => 'BacnetTimeValue($time = $value)';
}

/// The Weekly_Schedule of a Schedule object: the time values of each day,
/// Monday first.
@immutable
final class BacnetWeeklySchedule {
  /// Creates a weekly schedule from seven daily schedules, Monday first.
  BacnetWeeklySchedule(List<List<BacnetTimeValue>> days)
    : days = List.unmodifiable([for (final day in days) List.of(day)]) {
    if (days.length != 7) {
      throw ArgumentError.value(days.length, 'days', 'must be 7');
    }
  }

  /// Interprets a read value. Throws a [BacnetDecodeException] if it is not
  /// an array of seven BACnetDailySchedules.
  factory BacnetWeeklySchedule.fromValue(BacnetValue value) {
    final days = _items(value);
    if (days.length != 7) throw malformedConstruct('Weekly_Schedule', value);
    return BacnetWeeklySchedule([
      for (final day in days)
        switch (day) {
          BacnetConstructedValue(tag: 0, :final values) =>
            BacnetTimeValue._pairs(values, value),
          _ => throw malformedConstruct('BACnetDailySchedule', value),
        },
    ]);
  }

  /// The time values of each day, Monday (index 0) to Sunday (index 6).
  final List<List<BacnetTimeValue>> days;

  /// The time values of [weekday] (`DateTime.monday` .. `DateTime.sunday`).
  List<BacnetTimeValue> operator [](int weekday) => days[weekday - 1];

  /// The value to write.
  BacnetValue toValue() => BacnetList([
    for (final day in days)
      BacnetConstructedValue(0, BacnetTimeValue._flatten(day)),
  ]);

  @override
  bool operator ==(Object other) {
    if (other is! BacnetWeeklySchedule) return false;
    for (var i = 0; i < 7; i++) {
      if (!listEquals(other.days[i], days[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(days.map(Object.hashAll));

  @override
  String toString() => 'BacnetWeeklySchedule($days)';
}

/// A range of dates (BACnetDateRange), e.g. Effective_Period. `null`
/// fields of the dates are wildcards.
@immutable
final class BacnetDateRange {
  /// Creates a date range.
  const BacnetDateRange(this.start, this.end);

  /// Interprets a read value. Throws a [BacnetDecodeException] if it is not
  /// two dates.
  factory BacnetDateRange.fromValue(BacnetValue value) =>
      _fromItems(_items(value), value);

  static BacnetDateRange _fromItems(List<BacnetValue> items, Object source) {
    if (items case [final BacnetDate start, final BacnetDate end]) {
      return BacnetDateRange(start, end);
    }
    throw malformedConstruct('BACnetDateRange', source);
  }

  /// First day.
  final BacnetDate start;

  /// Last day.
  final BacnetDate end;

  /// The value to write.
  BacnetValue toValue() => BacnetList([start, end]);

  @override
  bool operator ==(Object other) =>
      other is BacnetDateRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'BacnetDateRange($start .. $end)';
}

/// Recurring days (BACnetWeekNDay): a month, a week of the month and a day
/// of the week; `null` matches any.
@immutable
final class BacnetWeekNDay {
  /// Creates a week-n-day pattern.
  const BacnetWeekNDay({this.month, this.weekOfMonth, this.dayOfWeek});

  /// Month 1..12, 13 odd months, 14 even months, or null for any.
  final int? month;

  /// 1 = days 1..7, ..., 5 = days 29..31, 6 = last 7 days, or null for any.
  final int? weekOfMonth;

  /// 1 = Monday .. 7 = Sunday, or null for any.
  final int? dayOfWeek;

  static BacnetWeekNDay _fromOctets(Uint8List octets, Object source) {
    if (octets.length != 3) throw malformedConstruct('BACnetWeekNDay', source);
    int? any(int v) => v == 0xFF ? null : v;
    return BacnetWeekNDay(
      month: any(octets[0]),
      weekOfMonth: any(octets[1]),
      dayOfWeek: any(octets[2]),
    );
  }

  Uint8List get _octets => Uint8List.fromList([
    month ?? 0xFF,
    weekOfMonth ?? 0xFF,
    dayOfWeek ?? 0xFF,
  ]);

  @override
  bool operator ==(Object other) =>
      other is BacnetWeekNDay &&
      other.month == month &&
      other.weekOfMonth == weekOfMonth &&
      other.dayOfWeek == dayOfWeek;

  @override
  int get hashCode => Object.hash(month, weekOfMonth, dayOfWeek);

  @override
  String toString() =>
      'BacnetWeekNDay(month: ${month ?? '*'}, week: ${weekOfMonth ?? '*'}, '
      'day: ${dayOfWeek ?? '*'})';
}

/// The days a special event applies to: a calendar entry or a reference to
/// a Calendar object.
@immutable
sealed class BacnetSpecialEventPeriod {
  const BacnetSpecialEventPeriod();
}

/// A reference to a Calendar object whose Present_Value selects the days.
final class BacnetCalendarReference extends BacnetSpecialEventPeriod {
  /// Creates the reference.
  const BacnetCalendarReference(this.calendar);

  /// The Calendar object.
  final BacnetObject calendar;

  @override
  bool operator ==(Object other) =>
      other is BacnetCalendarReference && other.calendar == calendar;

  @override
  int get hashCode => calendar.hashCode;

  @override
  String toString() => 'BacnetCalendarReference($calendar)';
}

/// An entry of a calendar (BACnetCalendarEntry): a date, a date range or a
/// week-n-day pattern. Date_List of a Calendar object holds a list of them.
sealed class BacnetCalendarEntry extends BacnetSpecialEventPeriod {
  const BacnetCalendarEntry();

  /// Interprets a read value. Throws a [BacnetDecodeException] for
  /// anything else.
  factory BacnetCalendarEntry.fromValue(BacnetValue value) => switch (value) {
    BacnetContextValue(tag: 0, :final data) => BacnetCalendarDate(
      constructPrimitive<BacnetDate>(data, BacnetApplicationTag.date, value),
    ),
    BacnetConstructedValue(tag: 1, :final values) => BacnetCalendarDateRange(
      BacnetDateRange._fromItems(values, value),
    ),
    BacnetContextValue(tag: 2, :final data) => BacnetCalendarWeekNDay(
      BacnetWeekNDay._fromOctets(data, value),
    ),
    _ => throw malformedConstruct('BACnetCalendarEntry', value),
  };

  /// Interprets a list of calendar entries (Date_List).
  static List<BacnetCalendarEntry> listFromValue(BacnetValue value) =>
      List.unmodifiable(_items(value).map(BacnetCalendarEntry.fromValue));

  /// The value to write.
  BacnetValue toValue();
}

/// A calendar entry for one date (fields may be wildcards).
final class BacnetCalendarDate extends BacnetCalendarEntry {
  /// Creates the entry.
  const BacnetCalendarDate(this.date);

  /// The date.
  final BacnetDate date;

  @override
  BacnetValue toValue() => contextValue(0, date);

  @override
  bool operator ==(Object other) =>
      other is BacnetCalendarDate && other.date == date;

  @override
  int get hashCode => date.hashCode;

  @override
  String toString() => 'BacnetCalendarDate($date)';
}

/// A calendar entry for a range of dates.
final class BacnetCalendarDateRange extends BacnetCalendarEntry {
  /// Creates the entry.
  const BacnetCalendarDateRange(this.range);

  /// The range.
  final BacnetDateRange range;

  @override
  BacnetValue toValue() => BacnetConstructedValue(1, [range.start, range.end]);

  @override
  bool operator ==(Object other) =>
      other is BacnetCalendarDateRange && other.range == range;

  @override
  int get hashCode => range.hashCode;

  @override
  String toString() => 'BacnetCalendarDateRange($range)';
}

/// A calendar entry for recurring days.
final class BacnetCalendarWeekNDay extends BacnetCalendarEntry {
  /// Creates the entry.
  const BacnetCalendarWeekNDay(this.pattern);

  /// The days.
  final BacnetWeekNDay pattern;

  @override
  BacnetValue toValue() => BacnetContextValue(2, pattern._octets);

  @override
  bool operator ==(Object other) =>
      other is BacnetCalendarWeekNDay && other.pattern == pattern;

  @override
  int get hashCode => pattern.hashCode;

  @override
  String toString() => 'BacnetCalendarWeekNDay($pattern)';
}

/// An exception to the weekly schedule (BACnetSpecialEvent): on the days of
/// [period] the [timeValues] apply with [priority].
@immutable
final class BacnetSpecialEvent {
  /// Creates a special event.
  BacnetSpecialEvent({
    required this.period,
    required List<BacnetTimeValue> timeValues,
    required this.priority,
  }) : timeValues = List.unmodifiable(timeValues) {
    if (priority < 1 || priority > 16) {
      throw ArgumentError.value(priority, 'priority', 'must be 1..16');
    }
  }

  /// Interprets the list of special events of an Exception_Schedule.
  /// Throws a [BacnetDecodeException] if it is malformed.
  static List<BacnetSpecialEvent> listFromValue(BacnetValue value) {
    final items = _items(value);
    final events = <BacnetSpecialEvent>[];
    var i = 0;
    while (i < items.length) {
      final period = switch (items[i]) {
        BacnetConstructedValue(tag: 0, values: [final entry]) =>
          BacnetCalendarEntry.fromValue(entry),
        BacnetContextValue(tag: 1, :final data) => BacnetCalendarReference(
          constructPrimitive<BacnetObject>(
            data,
            BacnetApplicationTag.objectIdentifier,
            value,
          ),
        ),
        _ => throw malformedConstruct('BACnetSpecialEvent', value),
      };
      if (i + 2 >= items.length) {
        throw malformedConstruct('BACnetSpecialEvent', value);
      }
      final timeValues = switch (items[i + 1]) {
        BacnetConstructedValue(tag: 2, :final values) => BacnetTimeValue._pairs(
          values,
          value,
        ),
        _ => throw malformedConstruct('BACnetSpecialEvent', value),
      };
      final priority = switch (items[i + 2]) {
        BacnetContextValue(tag: 3, :final data) =>
          constructPrimitive<BacnetUnsigned>(
            data,
            BacnetApplicationTag.unsignedInt,
            value,
          ).value,
        _ => throw malformedConstruct('BACnetSpecialEvent', value),
      };
      if (priority < 1 || priority > 16) {
        throw malformedConstruct('BACnetSpecialEvent priority', value);
      }
      events.add(
        BacnetSpecialEvent(
          period: period,
          timeValues: timeValues,
          priority: priority,
        ),
      );
      i += 3;
    }
    return List.unmodifiable(events);
  }

  /// Builds the value of an Exception_Schedule.
  static BacnetValue listToValue(List<BacnetSpecialEvent> events) =>
      BacnetList([for (final event in events) ...event._fields]);

  /// The days the event applies to.
  final BacnetSpecialEventPeriod period;

  /// The schedule of those days.
  final List<BacnetTimeValue> timeValues;

  /// Priority 1 (highest) .. 16 among overlapping events.
  final int priority;

  List<BacnetValue> get _fields => [
    switch (period) {
      final BacnetCalendarEntry entry => BacnetConstructedValue(0, [
        entry.toValue(),
      ]),
      BacnetCalendarReference(:final calendar) => contextValue(1, calendar),
    },
    BacnetConstructedValue(2, BacnetTimeValue._flatten(timeValues)),
    contextValue(3, BacnetUnsigned(priority)),
  ];

  @override
  bool operator ==(Object other) =>
      other is BacnetSpecialEvent &&
      other.period == period &&
      other.priority == priority &&
      listEquals(other.timeValues, timeValues);

  @override
  int get hashCode => Object.hash(period, priority, Object.hashAll(timeValues));

  @override
  String toString() =>
      'BacnetSpecialEvent($period, $timeValues, priority $priority)';
}

/// A reference to a property of an object, optionally in another device
/// (BACnetDeviceObjectPropertyReference), e.g. Log_DeviceObjectProperty of
/// a Trend Log or Object_Property_Reference of an Event Enrollment.
@immutable
final class BacnetDeviceObjectPropertyReference {
  /// Creates a reference.
  const BacnetDeviceObjectPropertyReference({
    required this.object,
    required this.property,
    this.arrayIndex,
    this.device,
  });

  /// Interprets a read value with one reference. Throws a
  /// [BacnetDecodeException] if it is malformed.
  factory BacnetDeviceObjectPropertyReference.fromValue(BacnetValue value) {
    final references = listFromValue(value);
    if (references.length != 1) {
      throw malformedConstruct('BACnetDeviceObjectPropertyReference', value);
    }
    return references.single;
  }

  /// Interprets a list of references (List_Of_Object_Property_References).
  static List<BacnetDeviceObjectPropertyReference> listFromValue(
    BacnetValue value,
  ) {
    final result = <BacnetDeviceObjectPropertyReference>[];
    final items = _items(value);
    var i = 0;
    T? optional<T extends BacnetValue>(int tag, int applicationTag) {
      if (i >= items.length) return null;
      final item = items[i];
      if (item is! BacnetContextValue || item.tag != tag) return null;
      i++;
      return constructPrimitive<T>(item.data, applicationTag, value);
    }

    while (i < items.length) {
      final object = optional<BacnetObject>(
        0,
        BacnetApplicationTag.objectIdentifier,
      );
      final property = optional<BacnetEnumerated>(
        1,
        BacnetApplicationTag.enumerated,
      );
      if (object == null || property == null) {
        throw malformedConstruct('BACnetDeviceObjectPropertyReference', value);
      }
      final index = optional<BacnetUnsigned>(
        2,
        BacnetApplicationTag.unsignedInt,
      );
      final device = optional<BacnetObject>(
        3,
        BacnetApplicationTag.objectIdentifier,
      );
      result.add(
        BacnetDeviceObjectPropertyReference(
          object: object,
          property: BacnetPropertyId(property.value),
          arrayIndex: index?.value,
          device: device,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  /// Builds the value of a list of references.
  static BacnetValue listToValue(
    List<BacnetDeviceObjectPropertyReference> references,
  ) => BacnetList([for (final reference in references) ...reference._fields]);

  /// The referenced object.
  final BacnetObject object;

  /// The referenced property.
  final BacnetPropertyId property;

  /// The array index, or null for the whole property.
  final int? arrayIndex;

  /// The device hosting [object], or null for the local device.
  final BacnetObject? device;

  List<BacnetValue> get _fields => [
    contextValue(0, object),
    contextValue(1, BacnetEnumerated(property)),
    if (arrayIndex case final index?) contextValue(2, BacnetUnsigned(index)),
    if (device case final device?) contextValue(3, device),
  ];

  /// The value to write.
  BacnetValue toValue() => BacnetList(_fields);

  @override
  bool operator ==(Object other) =>
      other is BacnetDeviceObjectPropertyReference &&
      other.object == object &&
      other.property == property &&
      other.arrayIndex == arrayIndex &&
      other.device == device;

  @override
  int get hashCode => Object.hash(object, property, arrayIndex, device);

  @override
  String toString() =>
      'BacnetDeviceObjectPropertyReference(${device == null ? '' : '$device '}'
      '$object ${property.label}${arrayIndex == null ? '' : '[$arrayIndex]'})';
}

/// A device address known to a device (BACnetAddressBinding), the entries
/// of Device_Address_Binding.
@immutable
final class BacnetAddressBinding {
  /// Creates a binding.
  BacnetAddressBinding({
    required this.device,
    required this.network,
    required List<int> mac,
  }) : mac = Uint8List.fromList(mac);

  /// Interprets the list of a Device_Address_Binding. Throws a
  /// [BacnetDecodeException] if it is malformed.
  static List<BacnetAddressBinding> listFromValue(BacnetValue value) {
    final items = _items(value);
    if (items.length % 3 != 0) {
      throw malformedConstruct('BACnetAddressBinding', value);
    }
    return List.unmodifiable([
      for (var i = 0; i < items.length; i += 3)
        switch ((items[i], items[i + 1], items[i + 2])) {
          (
            final BacnetObject device,
            BacnetUnsigned(value: final network),
            BacnetOctetString(value: final mac),
          ) =>
            BacnetAddressBinding(device: device, network: network, mac: mac),
          _ => throw malformedConstruct('BACnetAddressBinding', value),
        },
    ]);
  }

  /// The device.
  final BacnetObject device;

  /// Network number (0 = local network).
  final int network;

  /// MAC address (BACnet/IP: 4 bytes IPv4 + 2 bytes port).
  final Uint8List mac;

  /// IPv4 address, if BACnet/IP.
  String? get ipAddress =>
      mac.length == 6 ? '${mac[0]}.${mac[1]}.${mac[2]}.${mac[3]}' : null;

  /// UDP port, if BACnet/IP.
  int? get port => mac.length == 6 ? (mac[4] << 8) | mac[5] : null;

  @override
  bool operator ==(Object other) =>
      other is BacnetAddressBinding &&
      other.device == device &&
      other.network == network &&
      listEquals(other.mac, mac);

  @override
  int get hashCode => Object.hash(device, network, Object.hashAll(mac));

  @override
  String toString() =>
      'BacnetAddressBinding($device, network $network, '
      '${ipAddress != null ? '$ipAddress:$port' : mac})';
}

/// The event transitions of Event_Enable, Acked_Transitions and similar
/// properties (BACnetEventTransitionBits).
@immutable
final class BacnetEventTransitionBits {
  /// Creates transition bits.
  const BacnetEventTransitionBits({
    this.toOffNormal = false,
    this.toFault = false,
    this.toNormal = false,
  });

  /// Interprets a read value. Throws a [BacnetDecodeException] if it is not
  /// a bit string.
  factory BacnetEventTransitionBits.fromValue(BacnetValue value) =>
      switch (value) {
        final BacnetBitString bits => BacnetEventTransitionBits(
          toOffNormal: bits[0],
          toFault: bits[1],
          toNormal: bits[2],
        ),
        _ => throw malformedConstruct('BACnetEventTransitionBits', value),
      };

  /// TO-OFFNORMAL.
  final bool toOffNormal;

  /// TO-FAULT.
  final bool toFault;

  /// TO-NORMAL.
  final bool toNormal;

  /// The value to write.
  BacnetValue toValue() => BacnetBitString([toOffNormal, toFault, toNormal]);

  @override
  bool operator ==(Object other) =>
      other is BacnetEventTransitionBits &&
      other.toOffNormal == toOffNormal &&
      other.toFault == toFault &&
      other.toNormal == toNormal;

  @override
  int get hashCode => Object.hash(toOffNormal, toFault, toNormal);

  @override
  String toString() =>
      'BacnetEventTransitionBits(offNormal: $toOffNormal, fault: $toFault, '
      'normal: $toNormal)';
}

/// Which limits of an analog object report events (BACnetLimitEnable).
@immutable
final class BacnetLimitEnable {
  /// Creates limit enable flags.
  const BacnetLimitEnable({this.lowLimit = false, this.highLimit = false});

  /// Interprets a read value. Throws a [BacnetDecodeException] if it is not
  /// a bit string.
  factory BacnetLimitEnable.fromValue(BacnetValue value) => switch (value) {
    final BacnetBitString bits => BacnetLimitEnable(
      lowLimit: bits[0],
      highLimit: bits[1],
    ),
    _ => throw malformedConstruct('BACnetLimitEnable', value),
  };

  /// Low_Limit reports events.
  final bool lowLimit;

  /// High_Limit reports events.
  final bool highLimit;

  /// The value to write.
  BacnetValue toValue() => BacnetBitString([lowLimit, highLimit]);

  @override
  bool operator ==(Object other) =>
      other is BacnetLimitEnable &&
      other.lowLimit == lowLimit &&
      other.highLimit == highLimit;

  @override
  int get hashCode => Object.hash(lowLimit, highLimit);

  @override
  String toString() => 'BacnetLimitEnable(low: $lowLimit, high: $highLimit)';
}

/// The Priority_Array of a commandable object: the commanded value of each
/// priority, `BacnetNull` where nothing is commanded.
@immutable
final class BacnetPriorityArray {
  /// Creates a priority array from the values of priorities 1..16.
  BacnetPriorityArray(List<BacnetValue> slots)
    : slots = List.unmodifiable(slots) {
    if (slots.length != 16) {
      throw ArgumentError.value(slots.length, 'slots', 'must be 16');
    }
  }

  /// Interprets a read value. Throws a [BacnetDecodeException] if it is not
  /// an array of 16 values.
  factory BacnetPriorityArray.fromValue(BacnetValue value) {
    final slots = _items(value);
    if (slots.length != 16) throw malformedConstruct('Priority_Array', value);
    return BacnetPriorityArray(slots);
  }

  /// Values of priorities 1 (index 0) .. 16 (index 15).
  final List<BacnetValue> slots;

  /// The value commanded at [priority] (1..16).
  BacnetValue operator [](int priority) => slots[priority - 1];

  /// The highest priority with a commanded value, or null when all are
  /// relinquished (the object uses Relinquish_Default).
  int? get activePriority {
    final index = slots.indexWhere((slot) => slot is! BacnetNull);
    return index < 0 ? null : index + 1;
  }

  /// The value of [activePriority], or null.
  BacnetValue? get activeValue => switch (activePriority) {
    final priority? => this[priority],
    null => null,
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetPriorityArray && listEquals(other.slots, slots);

  @override
  int get hashCode => Object.hashAll(slots);

  @override
  String toString() =>
      'BacnetPriorityArray(${activePriority == null ? 'relinquished' : '$activeValue @ $activePriority'})';
}

/// A CIE 1931 xy chromaticity (BACnetxyColor), the Color property of a Color
/// object and the target of a [BacnetColorCommand]; [x] and [y] are 0.0..1.0.
@immutable
final class BacnetXYColor {
  /// Creates a chromaticity.
  const BacnetXYColor(this.x, this.y);

  /// Interprets a read value (a two-REAL sequence). Throws a
  /// [BacnetDecodeException] if it is malformed.
  factory BacnetXYColor.fromValue(BacnetValue value) {
    final items = _items(value);
    double real(int i) => switch (items.length > i ? items[i] : null) {
      BacnetReal(:final value) || BacnetDouble(:final value) => value,
      _ => throw malformedConstruct('BACnetxyColor', value),
    };
    if (items.length != 2) throw malformedConstruct('BACnetxyColor', value);
    return BacnetXYColor(real(0), real(1));
  }

  /// The x coordinate (0.0..1.0).
  final double x;

  /// The y coordinate (0.0..1.0).
  final double y;

  /// The value to write.
  BacnetValue toValue() => BacnetList([BacnetReal(x), BacnetReal(y)]);

  @override
  bool operator ==(Object other) =>
      other is BacnetXYColor && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'BacnetXYColor($x, $y)';
}

/// A BACnetLightingCommand, the Lighting_Command property of a Lighting
/// Output object (ASHRAE 135 clause 12.54.x). Only the fields the
/// [operation] uses are set; the rest are null.
@immutable
final class BacnetLightingCommand {
  /// Creates a lighting command.
  const BacnetLightingCommand({
    required this.operation,
    this.targetLevel,
    this.rampRate,
    this.stepIncrement,
    this.fadeTime,
    this.priority,
  });

  /// Interprets a read value. Throws a [BacnetDecodeException] if it is
  /// malformed.
  factory BacnetLightingCommand.fromValue(BacnetValue value) {
    final f = ConstructFields(_items(value), 'BACnetLightingCommand', value);
    final operation = BacnetLightingOperation(f.enumerated(0));
    return BacnetLightingCommand(
      operation: operation,
      targetLevel: f.has(1) ? f.real(1) : null,
      rampRate: f.has(2) ? f.real(2) : null,
      stepIncrement: f.has(3) ? f.real(3) : null,
      fadeTime: f.has(4) ? Duration(milliseconds: f.unsigned(4)) : null,
      priority: f.has(5) ? f.unsigned(5) : null,
    );
  }

  /// The operation to perform.
  final BacnetLightingOperation operation;

  /// Target level in percent (0.0..100.0), for fade and ramp operations.
  final double? targetLevel;

  /// Ramp rate in percent per second, for ramp operations.
  final double? rampRate;

  /// Step increment in percent, for step operations.
  final double? stepIncrement;

  /// Fade time, for fade operations.
  final Duration? fadeTime;

  /// Priority for writing (1..16).
  final int? priority;

  /// The value to write.
  BacnetValue toValue() => BacnetList([
    contextValue(0, BacnetEnumerated(operation)),
    if (targetLevel case final v?) contextValue(1, BacnetReal(v)),
    if (rampRate case final v?) contextValue(2, BacnetReal(v)),
    if (stepIncrement case final v?) contextValue(3, BacnetReal(v)),
    if (fadeTime case final v?)
      contextValue(4, BacnetUnsigned(v.inMilliseconds)),
    if (priority case final v?) contextValue(5, BacnetUnsigned(v)),
  ]);

  @override
  bool operator ==(Object other) =>
      other is BacnetLightingCommand &&
      other.operation == operation &&
      other.targetLevel == targetLevel &&
      other.rampRate == rampRate &&
      other.stepIncrement == stepIncrement &&
      other.fadeTime == fadeTime &&
      other.priority == priority;

  @override
  int get hashCode => Object.hash(
    operation,
    targetLevel,
    rampRate,
    stepIncrement,
    fadeTime,
    priority,
  );

  @override
  String toString() =>
      'BacnetLightingCommand(${operation.label}'
      '${targetLevel == null ? '' : ', level $targetLevel'}'
      '${fadeTime == null ? '' : ', fade ${fadeTime!.inMilliseconds}ms'}'
      '${rampRate == null ? '' : ', ramp $rampRate'}'
      '${stepIncrement == null ? '' : ', step $stepIncrement'}'
      '${priority == null ? '' : ', priority $priority'})';
}

/// A BACnetColorCommand, the Color_Command property of a Color or Color
/// Temperature object (ASHRAE 135). Only the fields the [operation] uses are
/// set; target color and temperature, and the transition fields, are
/// mutually exclusive.
@immutable
final class BacnetColorCommand {
  /// Creates a color command.
  const BacnetColorCommand({
    required this.operation,
    this.targetColor,
    this.targetColorTemperature,
    this.fadeTime,
    this.rampRate,
    this.stepIncrement,
  });

  /// Interprets a read value. Throws a [BacnetDecodeException] if it is
  /// malformed.
  factory BacnetColorCommand.fromValue(BacnetValue value) {
    final f = ConstructFields(_items(value), 'BACnetColorCommand', value);
    final operation = BacnetColorOperation(f.enumerated(0));
    return BacnetColorCommand(
      operation: operation,
      targetColor: f.has(1)
          ? BacnetXYColor.fromValue(BacnetList(f.constructed(1)))
          : null,
      targetColorTemperature: f.has(2) ? f.unsigned(2) : null,
      fadeTime: f.has(3) ? Duration(milliseconds: f.unsigned(3)) : null,
      rampRate: f.has(4) ? f.unsigned(4) : null,
      stepIncrement: f.has(5) ? f.unsigned(5) : null,
    );
  }

  /// The operation to perform.
  final BacnetColorOperation operation;

  /// Target chromaticity, for fade-to-color.
  final BacnetXYColor? targetColor;

  /// Target color temperature in kelvin, for the CCT operations.
  final int? targetColorTemperature;

  /// Fade time, for fade operations.
  final Duration? fadeTime;

  /// Ramp rate in kelvin per second, for ramp operations.
  final int? rampRate;

  /// Step increment in kelvin, for step operations.
  final int? stepIncrement;

  /// The value to write.
  BacnetValue toValue() => BacnetList([
    contextValue(0, BacnetEnumerated(operation)),
    if (targetColor case final c?)
      BacnetConstructedValue(1, [BacnetReal(c.x), BacnetReal(c.y)]),
    if (targetColorTemperature case final v?)
      contextValue(2, BacnetUnsigned(v)),
    if (fadeTime case final v?)
      contextValue(3, BacnetUnsigned(v.inMilliseconds)),
    if (rampRate case final v?) contextValue(4, BacnetUnsigned(v)),
    if (stepIncrement case final v?) contextValue(5, BacnetUnsigned(v)),
  ]);

  @override
  bool operator ==(Object other) =>
      other is BacnetColorCommand &&
      other.operation == operation &&
      other.targetColor == targetColor &&
      other.targetColorTemperature == targetColorTemperature &&
      other.fadeTime == fadeTime &&
      other.rampRate == rampRate &&
      other.stepIncrement == stepIncrement;

  @override
  int get hashCode => Object.hash(
    operation,
    targetColor,
    targetColorTemperature,
    fadeTime,
    rampRate,
    stepIncrement,
  );

  @override
  String toString() =>
      'BacnetColorCommand(${operation.label}'
      '${targetColor == null ? '' : ', $targetColor'}'
      '${targetColorTemperature == null ? '' : ', ${targetColorTemperature}K'}'
      '${fadeTime == null ? '' : ', fade ${fadeTime!.inMilliseconds}ms'}'
      '${rampRate == null ? '' : ', ramp $rampRate'}'
      '${stepIncrement == null ? '' : ', step $stepIncrement'})';
}

// ---- helpers -----------------------------------------------------------------

/// The items of a value: the elements of a list, the values of an untagged
/// sequence, or the value itself.
List<BacnetValue> _items(BacnetValue value) => value.asList;
