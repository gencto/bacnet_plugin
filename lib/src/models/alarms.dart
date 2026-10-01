/// @docImport '../client/bacnet_client.dart';
/// @docImport 'bacnet_property.dart';
/// @docImport 'events.dart';
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../codec/value_encoding.dart';
import '../constants/engineering_units.dart';
import '../constants/enumerations.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import 'bacnet_value.dart';
import 'complex_values.dart';
import 'construct_support.dart';
import 'wpm_models.dart';

// Typed forms of the datatypes of alarm and event reporting (ASHRAE 135
// clauses 13 and 21): the values an event notification reports, the
// summaries of GetEventInformation and GetAlarmSummary and the recipients
// of a Notification Class.

/// A state reported by a change-of-state event (BACnetPropertyStates): a
/// value of the enumeration [kind] selects.
///
/// ```dart
/// if (values case BacnetChangeOfStateValues(:final newState)) {
///   print(newState.asBinaryPV == BacnetBinaryPV.active ? 'on' : 'off');
/// }
/// ```
@immutable
final class BacnetPropertyState {
  /// Creates a state of [kind] with the encoded [value].
  const BacnetPropertyState(this.kind, this.value);

  /// A BOOLEAN state.
  const BacnetPropertyState.boolean(bool value)
    : this(BacnetPropertyStateKind.booleanValue, value ? 1 : 0);

  /// A state of a binary object.
  const BacnetPropertyState.binaryPV(BacnetBinaryPV value)
    : this(BacnetPropertyStateKind.binaryValue, value);

  /// An event state.
  const BacnetPropertyState.eventState(BacnetEventState value)
    : this(BacnetPropertyStateKind.eventState, value);

  /// A reliability.
  const BacnetPropertyState.reliability(BacnetReliability value)
    : this(BacnetPropertyStateKind.reliability, value);

  /// An Unsigned state (e.g. the state of a multi-state object).
  const BacnetPropertyState.unsigned(int value)
    : this(BacnetPropertyStateKind.unsignedValue, value);

  /// An INTEGER state.
  const BacnetPropertyState.integer(int value)
    : this(BacnetPropertyStateKind.integerValue, value);

  /// Interprets the choice as decoded (a context tagged primitive). Throws a
  /// [BacnetDecodeException] for anything else.
  factory BacnetPropertyState.fromValue(BacnetValue value) {
    if (value case BacnetContextValue(:final tag, :final data)) {
      final kind = BacnetPropertyStateKind(tag);
      return BacnetPropertyState(kind, switch (kind) {
        BacnetPropertyStateKind.booleanValue =>
          constructPrimitive<BacnetBoolean>(
                data,
                BacnetApplicationTag.boolean,
                value,
              ).value
              ? 1
              : 0,
        BacnetPropertyStateKind.integerValue =>
          constructPrimitive<BacnetSigned>(
            data,
            BacnetApplicationTag.signedInt,
            value,
          ).value,
        _ => constructPrimitive<BacnetUnsigned>(
          data,
          BacnetApplicationTag.unsignedInt,
          value,
        ).value,
      });
    }
    throw malformedConstruct('BACnetPropertyStates', value);
  }

  /// The enumeration of [value].
  final BacnetPropertyStateKind kind;

  /// The encoded value (0 or 1 for a BOOLEAN).
  final int value;

  /// The value of a BOOLEAN state, otherwise null.
  bool? get asBoolean =>
      kind == BacnetPropertyStateKind.booleanValue ? value != 0 : null;

  /// The value of a binary object state, otherwise null.
  BacnetBinaryPV? get asBinaryPV => kind == BacnetPropertyStateKind.binaryValue
      ? BacnetBinaryPV(value)
      : null;

  /// The value of an event type state, otherwise null.
  BacnetEventType? get asEventType =>
      kind == BacnetPropertyStateKind.eventType ? BacnetEventType(value) : null;

  /// The value of a polarity state, otherwise null.
  BacnetPolarity? get asPolarity =>
      kind == BacnetPropertyStateKind.polarity ? BacnetPolarity(value) : null;

  /// The value of a reliability state, otherwise null.
  BacnetReliability? get asReliability =>
      kind == BacnetPropertyStateKind.reliability
      ? BacnetReliability(value)
      : null;

  /// The value of an event state, otherwise null.
  BacnetEventState? get asEventState =>
      kind == BacnetPropertyStateKind.eventState
      ? BacnetEventState(value)
      : null;

  /// The value of a device status state, otherwise null.
  BacnetDeviceStatus? get asDeviceStatus =>
      kind == BacnetPropertyStateKind.systemStatus
      ? BacnetDeviceStatus(value)
      : null;

  /// The value of a units state, otherwise null.
  BacnetEngineeringUnits? get asUnits => kind == BacnetPropertyStateKind.units
      ? BacnetEngineeringUnits(value)
      : null;

  /// The value of an Unsigned state, otherwise null.
  int? get asUnsigned =>
      kind == BacnetPropertyStateKind.unsignedValue ? value : null;

  /// The value of an INTEGER state, otherwise null.
  int? get asInteger =>
      kind == BacnetPropertyStateKind.integerValue ? value : null;

  /// The encoded choice.
  BacnetValue toValue() => contextValue(kind, switch (kind) {
    BacnetPropertyStateKind.booleanValue => BacnetBoolean(value != 0),
    BacnetPropertyStateKind.integerValue => BacnetSigned(value),
    _ => BacnetUnsigned(value),
  });

  @override
  bool operator ==(Object other) =>
      other is BacnetPropertyState &&
      other.kind == kind &&
      other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() {
    final label =
        asBinaryPV?.label ??
        asEventState?.label ??
        asReliability?.label ??
        asEventType?.label ??
        asPolarity?.label ??
        asDeviceStatus?.label ??
        asUnits?.label ??
        asBoolean?.toString() ??
        '$value';
    return 'BacnetPropertyState(${kind.label}: $label)';
  }
}

/// The values an event notification reports (BACnetNotificationParameters),
/// one subclass per event algorithm.
///
/// The class is sealed, so a `switch` covers all algorithms:
///
/// ```dart
/// switch (event.eventValues) {
///   case BacnetOutOfRangeValues(:final exceedingValue, :final exceededLimit):
///     print('$exceedingValue is beyond $exceededLimit');
///   case BacnetChangeOfStateValues(:final newState):
///     print('new state $newState');
///   case final other?:
///     print(other);
///   case null:
///     print('no values (acknowledgement notification)');
/// }
/// ```
@immutable
sealed class BacnetEventValues {
  const BacnetEventValues();

  /// Interprets the choice as decoded (a [BacnetConstructedValue] whose tag
  /// is the event type). Algorithms without a typed class are returned as
  /// [BacnetOtherEventValues]; throws a [BacnetDecodeException] when the
  /// fields of a typed algorithm are malformed.
  factory BacnetEventValues.fromValue(BacnetValue value) {
    if (value is! BacnetConstructedValue) {
      throw malformedConstruct('BACnetNotificationParameters', value);
    }
    final f = ConstructFields(
      value.values,
      'BACnetNotificationParameters',
      value,
    );
    return switch (BacnetEventType(value.tag)) {
      BacnetEventType.changeOfBitstring => BacnetChangeOfBitstringValues(
        referencedBitstring: f.bitString(0),
        statusFlags: f.statusFlags(1),
      ),
      BacnetEventType.changeOfState => BacnetChangeOfStateValues(
        newState: BacnetPropertyState.fromValue(f.choice(0)),
        statusFlags: f.statusFlags(1),
      ),
      BacnetEventType.changeOfValue => switch (f.choice(0)) {
        BacnetContextValue(tag: 0, :final data) =>
          BacnetChangeOfValueValues.bits(
            constructPrimitive<BacnetBitString>(
              data,
              BacnetApplicationTag.bitString,
              value,
            ),
            statusFlags: f.statusFlags(1),
          ),
        BacnetContextValue(tag: 1, :final data) =>
          BacnetChangeOfValueValues.value(
            constructPrimitive<BacnetReal>(
              data,
              BacnetApplicationTag.real,
              value,
            ).value,
            statusFlags: f.statusFlags(1),
          ),
        _ => throw malformedConstruct('change-of-value', value),
      },
      BacnetEventType.commandFailure => BacnetCommandFailureValues(
        commandValue: collapseValues(f.constructed(0)),
        statusFlags: f.statusFlags(1),
        feedbackValue: collapseValues(f.constructed(2)),
      ),
      BacnetEventType.floatingLimit => BacnetFloatingLimitValues(
        referenceValue: f.real(0),
        statusFlags: f.statusFlags(1),
        setpointValue: f.real(2),
        errorLimit: f.real(3),
      ),
      BacnetEventType.outOfRange => BacnetOutOfRangeValues(
        exceedingValue: f.real(0),
        statusFlags: f.statusFlags(1),
        deadband: f.real(2),
        exceededLimit: f.real(3),
      ),
      BacnetEventType.changeOfLifeSafety => BacnetChangeOfLifeSafetyValues(
        newState: f.enumerated(0),
        newMode: f.enumerated(1),
        statusFlags: f.statusFlags(2),
        operationExpected: f.enumerated(3),
      ),
      BacnetEventType.bufferReady => BacnetBufferReadyValues(
        bufferProperty: BacnetDeviceObjectPropertyReference.fromValue(
          BacnetList(f.constructed(0)),
        ),
        previousNotification: f.unsigned(1),
        currentNotification: f.unsigned(2),
      ),
      BacnetEventType.unsignedRange => BacnetUnsignedRangeValues(
        exceedingValue: f.unsigned(0),
        statusFlags: f.statusFlags(1),
        exceededLimit: f.unsigned(2),
      ),
      BacnetEventType.doubleOutOfRange => BacnetDoubleOutOfRangeValues(
        exceedingValue: f.doubleValue(0),
        statusFlags: f.statusFlags(1),
        deadband: f.doubleValue(2),
        exceededLimit: f.doubleValue(3),
      ),
      BacnetEventType.signedOutOfRange => BacnetSignedOutOfRangeValues(
        exceedingValue: f.signed(0),
        statusFlags: f.statusFlags(1),
        deadband: f.unsigned(2),
        exceededLimit: f.signed(3),
      ),
      BacnetEventType.unsignedOutOfRange => BacnetUnsignedOutOfRangeValues(
        exceedingValue: f.unsigned(0),
        statusFlags: f.statusFlags(1),
        deadband: f.unsigned(2),
        exceededLimit: f.unsigned(3),
      ),
      BacnetEventType.changeOfCharacterString =>
        BacnetChangeOfCharacterStringValues(
          changedValue: f.characterString(0),
          statusFlags: f.statusFlags(1),
          alarmValue: f.characterString(2),
        ),
      BacnetEventType.changeOfStatusFlags => BacnetChangeOfStatusFlagsValues(
        presentValue: f.has(0) ? collapseValues(f.constructed(0)) : null,
        referencedFlags: f.statusFlags(1),
      ),
      BacnetEventType.changeOfReliability => BacnetChangeOfReliabilityValues(
        reliability: BacnetReliability(f.enumerated(0)),
        statusFlags: f.statusFlags(1),
        propertyValues: _propertyValues(f.constructed(2), value),
      ),
      final type => BacnetOtherEventValues(type, value.values),
    };
  }

  /// The event algorithm (the event type of the notification).
  BacnetEventType get eventType;

  /// Status_Flags of the object, if the algorithm reports them.
  BacnetStatusFlags? get statusFlags;

  /// The fields of the algorithm.
  List<BacnetValue> get _fields;

  /// The encoded choice.
  BacnetValue toValue() => BacnetConstructedValue(eventType, _fields);

  @override
  bool operator ==(Object other) =>
      other is BacnetEventValues &&
      other.eventType == eventType &&
      listEquals(other._fields, _fields);

  @override
  int get hashCode => Object.hash(eventType, Object.hashAll(_fields));

  @override
  String toString() => '$runtimeType(${_describe()})';

  String _describe();
}

BacnetValue _flags(BacnetStatusFlags flags) => flags.toBitString();

/// CHANGE_OF_BITSTRING: a bit string property changed.
final class BacnetChangeOfBitstringValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetChangeOfBitstringValues({
    required this.referencedBitstring,
    required this.statusFlags,
  });

  /// The new value of the monitored bit string.
  final BacnetBitString referencedBitstring;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.changeOfBitstring;

  @override
  List<BacnetValue> get _fields => [
    contextValue(0, referencedBitstring),
    contextValue(1, _flags(statusFlags)),
  ];

  @override
  String _describe() => '$referencedBitstring';
}

/// CHANGE_OF_STATE: a binary or multi-state value changed.
final class BacnetChangeOfStateValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetChangeOfStateValues({
    required this.newState,
    required this.statusFlags,
  });

  /// The new state.
  final BacnetPropertyState newState;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.changeOfState;

  @override
  List<BacnetValue> get _fields => [
    BacnetConstructedValue(0, [newState.toValue()]),
    contextValue(1, _flags(statusFlags)),
  ];

  @override
  String _describe() => '$newState';
}

/// CHANGE_OF_VALUE: a value changed by more than an increment, or bits of
/// a bit string changed.
final class BacnetChangeOfValueValues extends BacnetEventValues {
  /// Creates the values for changed bits.
  const BacnetChangeOfValueValues.bits(
    BacnetBitString this.changedBits, {
    required this.statusFlags,
  }) : changedValue = null;

  /// Creates the values for a changed number.
  const BacnetChangeOfValueValues.value(
    double this.changedValue, {
    required this.statusFlags,
  }) : changedBits = null;

  /// The bits that changed, for a bit string.
  final BacnetBitString? changedBits;

  /// The amount of the change, for a number.
  final double? changedValue;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.changeOfValue;

  @override
  List<BacnetValue> get _fields => [
    BacnetConstructedValue(0, [
      if (changedBits case final bits?)
        contextValue(0, bits)
      else
        contextValue(1, BacnetReal(changedValue ?? 0)),
    ]),
    contextValue(1, _flags(statusFlags)),
  ];

  @override
  String _describe() => '${changedBits ?? changedValue}';
}

/// COMMAND_FAILURE: the feedback of a commanded object does not follow the
/// command.
final class BacnetCommandFailureValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetCommandFailureValues({
    required this.commandValue,
    required this.statusFlags,
    required this.feedbackValue,
  });

  /// The commanded value.
  final BacnetValue commandValue;

  /// The value of the feedback property.
  final BacnetValue feedbackValue;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.commandFailure;

  @override
  List<BacnetValue> get _fields => [
    BacnetConstructedValue(0, commandValue.asList),
    contextValue(1, _flags(statusFlags)),
    BacnetConstructedValue(2, feedbackValue.asList),
  ];

  @override
  String _describe() => 'command $commandValue, feedback $feedbackValue';
}

/// FLOATING_LIMIT: a value left the band around a moving setpoint.
final class BacnetFloatingLimitValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetFloatingLimitValues({
    required this.referenceValue,
    required this.statusFlags,
    required this.setpointValue,
    required this.errorLimit,
  });

  /// The monitored value.
  final double referenceValue;

  /// The setpoint.
  final double setpointValue;

  /// The limit that was exceeded.
  final double errorLimit;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.floatingLimit;

  @override
  List<BacnetValue> get _fields => [
    contextValue(0, BacnetReal(referenceValue)),
    contextValue(1, _flags(statusFlags)),
    contextValue(2, BacnetReal(setpointValue)),
    contextValue(3, BacnetReal(errorLimit)),
  ];

  @override
  String _describe() =>
      '$referenceValue, setpoint $setpointValue, limit $errorLimit';
}

/// OUT_OF_RANGE: a REAL value exceeded High_Limit or Low_Limit (the
/// intrinsic reporting of analog objects).
final class BacnetOutOfRangeValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetOutOfRangeValues({
    required this.exceedingValue,
    required this.statusFlags,
    required this.deadband,
    required this.exceededLimit,
  });

  /// The value that exceeded the limit.
  final double exceedingValue;

  /// The deadband of the limit.
  final double deadband;

  /// The limit that was exceeded.
  final double exceededLimit;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.outOfRange;

  @override
  List<BacnetValue> get _fields => [
    contextValue(0, BacnetReal(exceedingValue)),
    contextValue(1, _flags(statusFlags)),
    contextValue(2, BacnetReal(deadband)),
    contextValue(3, BacnetReal(exceededLimit)),
  ];

  @override
  String _describe() =>
      '$exceedingValue, limit $exceededLimit, deadband $deadband';
}

/// CHANGE_OF_LIFE_SAFETY: the state or mode of a life safety object
/// changed. States, modes and operations are BACnetLifeSafetyState,
/// BACnetLifeSafetyMode and BACnetLifeSafetyOperation values.
final class BacnetChangeOfLifeSafetyValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetChangeOfLifeSafetyValues({
    required this.newState,
    required this.newMode,
    required this.statusFlags,
    required this.operationExpected,
  });

  /// The new BACnetLifeSafetyState.
  final int newState;

  /// The new BACnetLifeSafetyMode.
  final int newMode;

  /// The expected BACnetLifeSafetyOperation.
  final int operationExpected;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.changeOfLifeSafety;

  @override
  List<BacnetValue> get _fields => [
    contextValue(0, BacnetEnumerated(newState)),
    contextValue(1, BacnetEnumerated(newMode)),
    contextValue(2, _flags(statusFlags)),
    contextValue(3, BacnetEnumerated(operationExpected)),
  ];

  @override
  String _describe() =>
      'state $newState, mode $newMode, operation $operationExpected';
}

/// BUFFER_READY: a log buffer collected enough new records (e.g. a Trend
/// Log reached its Notification_Threshold).
final class BacnetBufferReadyValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetBufferReadyValues({
    required this.bufferProperty,
    required this.previousNotification,
    required this.currentNotification,
  });

  /// The buffer (e.g. Log_Buffer of a Trend Log).
  final BacnetDeviceObjectPropertyReference bufferProperty;

  /// Sequence number of the last record of the previous notification.
  final int previousNotification;

  /// Sequence number of the newest record.
  final int currentNotification;

  @override
  BacnetStatusFlags? get statusFlags => null;

  @override
  BacnetEventType get eventType => BacnetEventType.bufferReady;

  @override
  List<BacnetValue> get _fields => [
    BacnetConstructedValue(0, bufferProperty.toValue().asList),
    contextValue(1, BacnetUnsigned(previousNotification)),
    contextValue(2, BacnetUnsigned(currentNotification)),
  ];

  @override
  String _describe() =>
      '$bufferProperty, records $previousNotification..$currentNotification';
}

/// UNSIGNED_RANGE: an Unsigned value left its range.
final class BacnetUnsignedRangeValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetUnsignedRangeValues({
    required this.exceedingValue,
    required this.statusFlags,
    required this.exceededLimit,
  });

  /// The value that exceeded the limit.
  final int exceedingValue;

  /// The limit that was exceeded.
  final int exceededLimit;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.unsignedRange;

  @override
  List<BacnetValue> get _fields => [
    contextValue(0, BacnetUnsigned(exceedingValue)),
    contextValue(1, _flags(statusFlags)),
    contextValue(2, BacnetUnsigned(exceededLimit)),
  ];

  @override
  String _describe() => '$exceedingValue, limit $exceededLimit';
}

/// DOUBLE_OUT_OF_RANGE: a Double value exceeded a limit.
final class BacnetDoubleOutOfRangeValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetDoubleOutOfRangeValues({
    required this.exceedingValue,
    required this.statusFlags,
    required this.deadband,
    required this.exceededLimit,
  });

  /// The value that exceeded the limit.
  final double exceedingValue;

  /// The deadband of the limit.
  final double deadband;

  /// The limit that was exceeded.
  final double exceededLimit;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.doubleOutOfRange;

  @override
  List<BacnetValue> get _fields => [
    contextValue(0, BacnetDouble(exceedingValue)),
    contextValue(1, _flags(statusFlags)),
    contextValue(2, BacnetDouble(deadband)),
    contextValue(3, BacnetDouble(exceededLimit)),
  ];

  @override
  String _describe() =>
      '$exceedingValue, limit $exceededLimit, deadband $deadband';
}

/// SIGNED_OUT_OF_RANGE: an INTEGER value exceeded a limit.
final class BacnetSignedOutOfRangeValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetSignedOutOfRangeValues({
    required this.exceedingValue,
    required this.statusFlags,
    required this.deadband,
    required this.exceededLimit,
  });

  /// The value that exceeded the limit.
  final int exceedingValue;

  /// The deadband of the limit.
  final int deadband;

  /// The limit that was exceeded.
  final int exceededLimit;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.signedOutOfRange;

  @override
  List<BacnetValue> get _fields => [
    contextValue(0, BacnetSigned(exceedingValue)),
    contextValue(1, _flags(statusFlags)),
    contextValue(2, BacnetUnsigned(deadband)),
    contextValue(3, BacnetSigned(exceededLimit)),
  ];

  @override
  String _describe() =>
      '$exceedingValue, limit $exceededLimit, deadband $deadband';
}

/// UNSIGNED_OUT_OF_RANGE: an Unsigned value exceeded a limit.
final class BacnetUnsignedOutOfRangeValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetUnsignedOutOfRangeValues({
    required this.exceedingValue,
    required this.statusFlags,
    required this.deadband,
    required this.exceededLimit,
  });

  /// The value that exceeded the limit.
  final int exceedingValue;

  /// The deadband of the limit.
  final int deadband;

  /// The limit that was exceeded.
  final int exceededLimit;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.unsignedOutOfRange;

  @override
  List<BacnetValue> get _fields => [
    contextValue(0, BacnetUnsigned(exceedingValue)),
    contextValue(1, _flags(statusFlags)),
    contextValue(2, BacnetUnsigned(deadband)),
    contextValue(3, BacnetUnsigned(exceededLimit)),
  ];

  @override
  String _describe() =>
      '$exceedingValue, limit $exceededLimit, deadband $deadband';
}

/// CHANGE_OF_CHARACTERSTRING: a character string took an alarm value.
final class BacnetChangeOfCharacterStringValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetChangeOfCharacterStringValues({
    required this.changedValue,
    required this.statusFlags,
    required this.alarmValue,
  });

  /// The new value.
  final String changedValue;

  /// The alarm value it matched.
  final String alarmValue;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.changeOfCharacterString;

  @override
  List<BacnetValue> get _fields => [
    contextValue(0, BacnetCharacterString(changedValue)),
    contextValue(1, _flags(statusFlags)),
    contextValue(2, BacnetCharacterString(alarmValue)),
  ];

  @override
  String _describe() => '"$changedValue" matches "$alarmValue"';
}

/// CHANGE_OF_STATUS_FLAGS: the Status_Flags of an object changed.
final class BacnetChangeOfStatusFlagsValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetChangeOfStatusFlagsValues({
    required this.referencedFlags,
    this.presentValue,
  });

  /// The Present_Value, if reported.
  final BacnetValue? presentValue;

  /// The new Status_Flags.
  final BacnetStatusFlags referencedFlags;

  @override
  BacnetStatusFlags get statusFlags => referencedFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.changeOfStatusFlags;

  @override
  List<BacnetValue> get _fields => [
    if (presentValue case final value?) BacnetConstructedValue(0, value.asList),
    contextValue(1, _flags(referencedFlags)),
  ];

  @override
  String _describe() => '$referencedFlags, value $presentValue';
}

/// CHANGE_OF_RELIABILITY: the Reliability of an object changed (the fault
/// algorithm of intrinsic reporting).
final class BacnetChangeOfReliabilityValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetChangeOfReliabilityValues({
    required this.reliability,
    required this.statusFlags,
    this.propertyValues = const [],
  });

  /// The new reliability.
  final BacnetReliability reliability;

  /// Further properties of the object the device reports.
  final List<BacnetPropertyValue> propertyValues;

  @override
  final BacnetStatusFlags statusFlags;

  @override
  BacnetEventType get eventType => BacnetEventType.changeOfReliability;

  @override
  List<BacnetValue> get _fields => [
    contextValue(0, BacnetEnumerated(reliability)),
    contextValue(1, _flags(statusFlags)),
    BacnetConstructedValue(2, [
      for (final p in propertyValues) ...[
        contextValue(0, BacnetEnumerated(p.propertyIdentifier)),
        if (p.propertyArrayIndex >= 0)
          contextValue(1, BacnetUnsigned(p.propertyArrayIndex)),
        BacnetConstructedValue(2, p.value.asList),
        if (p.priority >= 1 && p.priority < 16)
          contextValue(3, BacnetUnsigned(p.priority)),
      ],
    ]),
  ];

  @override
  String _describe() => '${reliability.label}, $propertyValues';
}

/// The values of an algorithm without a typed class (complex, extended,
/// access, discrete value, timer and proprietary event types).
final class BacnetOtherEventValues extends BacnetEventValues {
  /// Creates the values.
  const BacnetOtherEventValues(this.eventType, this.fields);

  @override
  final BacnetEventType eventType;

  /// The fields as decoded.
  final List<BacnetValue> fields;

  @override
  BacnetStatusFlags? get statusFlags => null;

  @override
  List<BacnetValue> get _fields => fields;

  @override
  String _describe() => '${eventType.label}: $fields';
}

List<BacnetPropertyValue> _propertyValues(
  List<BacnetValue> items,
  Object source,
) {
  final f = ConstructFields(items, 'BACnetPropertyValue', source);
  final result = <BacnetPropertyValue>[];
  while (f.has(0)) {
    final property = BacnetPropertyId(f.enumerated(0));
    final index = f.has(1) ? f.unsigned(1) : -1;
    final value = collapseValues(f.constructed(2));
    final priority = f.has(3) ? f.unsigned(3) : 16;
    result.add(
      BacnetPropertyValue(
        propertyIdentifier: property,
        propertyArrayIndex: index,
        value: value,
        priority: priority,
      ),
    );
  }
  return List.unmodifiable(result);
}

/// The three event transitions in the order of Event_Time_Stamps, Priority
/// and similar arrays.
enum BacnetEventTransition {
  /// Transition to an off-normal state (alarm).
  toOffNormal,

  /// Transition to fault.
  toFault,

  /// Transition back to normal.
  toNormal;

  /// The transition that leads into [state].
  static BacnetEventTransition into(BacnetEventState state) => switch (state) {
    BacnetEventState.normal => toNormal,
    BacnetEventState.fault => toFault,
    _ => toOffNormal,
  };
}

/// An object with an active event state, or with transitions not yet
/// acknowledged (an entry of the GetEventInformation answer).
@immutable
final class BacnetEventSummary {
  /// Creates a summary.
  const BacnetEventSummary({
    required this.object,
    required this.eventState,
    required this.acknowledgedTransitions,
    required this.eventTimeStamps,
    required this.notifyType,
    required this.eventEnable,
    required this.eventPriorities,
  });

  /// The object.
  final BacnetObject object;

  /// Its event state.
  final BacnetEventState eventState;

  /// The transitions that were acknowledged (or need no acknowledgement).
  final BacnetEventTransitionBits acknowledgedTransitions;

  /// When the transitions to off-normal, fault and normal happened last.
  final List<BacnetTimeStamp> eventTimeStamps;

  /// Alarm or event.
  final BacnetNotifyType notifyType;

  /// The transitions the object reports.
  final BacnetEventTransitionBits eventEnable;

  /// Priorities of the transitions to off-normal, fault and normal.
  final List<int> eventPriorities;

  /// When [eventState] was entered.
  BacnetTimeStamp? get stateTimeStamp =>
      timeStampOf(BacnetEventTransition.into(eventState));

  /// When [transition] happened last.
  BacnetTimeStamp? timeStampOf(BacnetEventTransition transition) =>
      transition.index < eventTimeStamps.length
      ? eventTimeStamps[transition.index]
      : null;

  /// The event state to acknowledge [transition] with: [eventState] for
  /// the transition into it, otherwise the state the transition leads to
  /// (off-normal for an earlier alarm).
  BacnetEventState stateOf(BacnetEventTransition transition) =>
      BacnetEventTransition.into(eventState) == transition
      ? eventState
      : switch (transition) {
          BacnetEventTransition.toOffNormal => BacnetEventState.offNormal,
          BacnetEventTransition.toFault => BacnetEventState.fault,
          BacnetEventTransition.toNormal => BacnetEventState.normal,
        };

  /// The transitions that wait for an acknowledgement, e.g. an alarm that
  /// returned to normal but was not acknowledged.
  ///
  /// ```dart
  /// for (final transition in summary.unacknowledgedTransitions) {
  ///   await client.acknowledgeAlarm(deviceId, summary.object,
  ///       summary.stateOf(transition), summary.timeStampOf(transition)!,
  ///       source: 'operator');
  /// }
  /// ```
  List<BacnetEventTransition> get unacknowledgedTransitions => [
    if (!acknowledgedTransitions.toOffNormal) BacnetEventTransition.toOffNormal,
    if (!acknowledgedTransitions.toFault) BacnetEventTransition.toFault,
    if (!acknowledgedTransitions.toNormal) BacnetEventTransition.toNormal,
  ];

  /// True when a transition waits for an acknowledgement.
  bool get isUnacknowledged => unacknowledgedTransitions.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is BacnetEventSummary &&
      other.object == object &&
      other.eventState == eventState &&
      other.acknowledgedTransitions == acknowledgedTransitions &&
      listEquals(other.eventTimeStamps, eventTimeStamps) &&
      other.notifyType == notifyType &&
      other.eventEnable == eventEnable &&
      listEquals(other.eventPriorities, eventPriorities);

  @override
  int get hashCode => Object.hash(
    object,
    eventState,
    acknowledgedTransitions,
    Object.hashAll(eventTimeStamps),
    notifyType,
    eventEnable,
    Object.hashAll(eventPriorities),
  );

  @override
  String toString() =>
      'BacnetEventSummary($object ${eventState.label}, '
      'acked $acknowledgedTransitions)';
}

/// An object in alarm (an entry of the GetAlarmSummary answer).
@immutable
final class BacnetAlarmSummary {
  /// Creates a summary.
  const BacnetAlarmSummary({
    required this.object,
    required this.alarmState,
    required this.acknowledgedTransitions,
  });

  /// The object.
  final BacnetObject object;

  /// Its event state.
  final BacnetEventState alarmState;

  /// The transitions that were acknowledged.
  final BacnetEventTransitionBits acknowledgedTransitions;

  @override
  bool operator ==(Object other) =>
      other is BacnetAlarmSummary &&
      other.object == object &&
      other.alarmState == alarmState &&
      other.acknowledgedTransitions == acknowledgedTransitions;

  @override
  int get hashCode => Object.hash(object, alarmState, acknowledgedTransitions);

  @override
  String toString() =>
      'BacnetAlarmSummary($object ${alarmState.label}, '
      'acked $acknowledgedTransitions)';
}

/// Priorities of the transitions to off-normal, fault and normal (the
/// Priority array of a Notification Class); 0 is the highest priority, 255
/// the lowest.
@immutable
final class BacnetEventPriorities {
  /// Creates the priorities.
  const BacnetEventPriorities({
    required this.toOffNormal,
    required this.toFault,
    required this.toNormal,
  });

  /// Interprets a read value. Throws a [BacnetDecodeException] if it is not
  /// an array of three Unsigned.
  factory BacnetEventPriorities.fromValue(BacnetValue value) =>
      switch (value.asList) {
        [
          BacnetUnsigned(value: final offNormal),
          BacnetUnsigned(value: final fault),
          BacnetUnsigned(value: final normal),
        ] =>
          BacnetEventPriorities(
            toOffNormal: offNormal,
            toFault: fault,
            toNormal: normal,
          ),
        _ => throw malformedConstruct('Priority', value),
      };

  /// Priority of transitions to off-normal.
  final int toOffNormal;

  /// Priority of transitions to fault.
  final int toFault;

  /// Priority of transitions to normal.
  final int toNormal;

  /// The priority of [transition].
  int operator [](BacnetEventTransition transition) => switch (transition) {
    BacnetEventTransition.toOffNormal => toOffNormal,
    BacnetEventTransition.toFault => toFault,
    BacnetEventTransition.toNormal => toNormal,
  };

  /// The value to write.
  BacnetValue toValue() => BacnetList([
    BacnetUnsigned(toOffNormal),
    BacnetUnsigned(toFault),
    BacnetUnsigned(toNormal),
  ]);

  @override
  bool operator ==(Object other) =>
      other is BacnetEventPriorities &&
      other.toOffNormal == toOffNormal &&
      other.toFault == toFault &&
      other.toNormal == toNormal;

  @override
  int get hashCode => Object.hash(toOffNormal, toFault, toNormal);

  @override
  String toString() =>
      'BacnetEventPriorities(offNormal: $toOffNormal, fault: $toFault, '
      'normal: $toNormal)';
}

/// Days of the week (BACnetDaysOfWeek), e.g. the days a recipient
/// receives notifications.
@immutable
final class BacnetDaysOfWeek {
  /// Creates the set from [DateTime] weekdays ([DateTime.monday] ..
  /// [DateTime.sunday]).
  BacnetDaysOfWeek(Iterable<int> weekdays)
    : _bits = weekdays.fold(0, (bits, day) {
        if (day < DateTime.monday || day > DateTime.sunday) {
          throw RangeError.range(day, DateTime.monday, DateTime.sunday);
        }
        return bits | (1 << (day - 1));
      });

  const BacnetDaysOfWeek._(this._bits);

  /// Every day.
  static const BacnetDaysOfWeek all = BacnetDaysOfWeek._(0x7F);

  /// Monday to Friday.
  static const BacnetDaysOfWeek workdays = BacnetDaysOfWeek._(0x1F);

  /// Interprets a bit string (bit 0 Monday .. bit 6 Sunday).
  factory BacnetDaysOfWeek.fromBitString(BacnetBitString bits) =>
      BacnetDaysOfWeek._(
        Iterable<int>.generate(
          7,
        ).fold(0, (mask, day) => bits[day] ? mask | (1 << day) : mask),
      );

  final int _bits;

  /// True when [weekday] ([DateTime.monday] .. [DateTime.sunday]) is
  /// included.
  bool contains(int weekday) =>
      weekday >= DateTime.monday &&
      weekday <= DateTime.sunday &&
      _bits & (1 << (weekday - 1)) != 0;

  /// The included weekdays ([DateTime.monday] .. [DateTime.sunday]).
  List<int> get weekdays => [
    for (var day = DateTime.monday; day <= DateTime.sunday; day++)
      if (contains(day)) day,
  ];

  /// The encoded bit string.
  BacnetBitString toBitString() =>
      BacnetBitString([for (var i = 0; i < 7; i++) _bits & (1 << i) != 0]);

  @override
  bool operator ==(Object other) =>
      other is BacnetDaysOfWeek && other._bits == _bits;

  @override
  int get hashCode => _bits;

  @override
  String toString() => 'BacnetDaysOfWeek($weekdays)';
}

/// Where notifications go (BACnetRecipient): a device, found by its
/// instance, or an address.
@immutable
sealed class BacnetRecipient {
  const BacnetRecipient();

  /// The device [deviceId] (the notifying device resolves its address with
  /// Who-Is).
  const factory BacnetRecipient.device(int deviceId) = BacnetDeviceRecipient;

  /// The BACnet/IP address [ip]:[port] on [network] (0 for the local
  /// network).
  factory BacnetRecipient.ip(String ip, int port, {int network = 0}) {
    final octets = ip.split('.').map(int.tryParse).toList();
    if (octets.length != 4 ||
        octets.any((o) => o == null || o < 0 || o > 255) ||
        port < 0 ||
        port > 0xFFFF) {
      throw ArgumentError('not an IPv4 address and port: $ip:$port');
    }
    return BacnetAddressRecipient(
      network: network,
      mac: [...octets.cast<int>(), port >> 8, port & 0xFF],
    );
  }

  /// The encoded choice.
  BacnetValue toValue();
}

/// A recipient device.
final class BacnetDeviceRecipient extends BacnetRecipient {
  /// Creates the recipient.
  const BacnetDeviceRecipient(this.deviceId);

  /// The device instance.
  final int deviceId;

  @override
  BacnetValue toValue() => contextValue(
    0,
    BacnetObject(type: BacnetObjectType.device, instance: deviceId),
  );

  @override
  bool operator ==(Object other) =>
      other is BacnetDeviceRecipient && other.deviceId == deviceId;

  @override
  int get hashCode => deviceId.hashCode;

  @override
  String toString() => 'BacnetDeviceRecipient($deviceId)';
}

/// A recipient address (BACnetAddress).
final class BacnetAddressRecipient extends BacnetRecipient {
  /// Creates the recipient.
  BacnetAddressRecipient({required this.network, required List<int> mac})
    : mac = Uint8List.fromList(mac);

  /// Network number (0 = local network).
  final int network;

  /// MAC address (BACnet/IP: 4 bytes IPv4 + 2 bytes port; empty for a
  /// broadcast).
  final Uint8List mac;

  /// IPv4 address, if BACnet/IP.
  String? get ipAddress =>
      mac.length == 6 ? '${mac[0]}.${mac[1]}.${mac[2]}.${mac[3]}' : null;

  /// UDP port, if BACnet/IP.
  int? get port => mac.length == 6 ? (mac[4] << 8) | mac[5] : null;

  @override
  BacnetValue toValue() => BacnetConstructedValue(1, [
    BacnetUnsigned(network),
    BacnetOctetString(mac),
  ]);

  @override
  bool operator ==(Object other) =>
      other is BacnetAddressRecipient &&
      other.network == network &&
      listEquals(other.mac, mac);

  @override
  int get hashCode => Object.hash(network, Object.hashAll(mac));

  @override
  String toString() =>
      'BacnetAddressRecipient(${ipAddress != null ? '$ipAddress:$port' : mac}'
      '${network == 0 ? '' : ' on network $network'})';
}

/// A recipient of the notifications of a Notification Class
/// (BACnetDestination), an entry of its Recipient_List.
///
/// ```dart
/// // receive the alarms of notification class 1 of device 1234
/// await client.addListElements(
///   1234,
///   const BacnetObject(type: BacnetObjectType.notificationClass, instance: 1),
///   BacnetProperties.recipientList,
///   [BacnetDestination(recipient: BacnetRecipient.ip('192.168.1.10', 47808))],
/// );
/// ```
@immutable
final class BacnetDestination {
  /// Creates a destination that receives all transitions at any time.
  BacnetDestination({
    required this.recipient,
    BacnetDaysOfWeek? validDays,
    this.fromTime = const BacnetTime(
      hour: 0,
      minute: 0,
      second: 0,
      hundredths: 0,
    ),
    this.toTime = const BacnetTime(
      hour: 23,
      minute: 59,
      second: 59,
      hundredths: 99,
    ),
    this.processId = 0,
    this.issueConfirmedNotifications = false,
    this.transitions = const BacnetEventTransitionBits(
      toOffNormal: true,
      toFault: true,
      toNormal: true,
    ),
  }) : validDays = validDays ?? BacnetDaysOfWeek.all;

  /// Interprets a Recipient_List. Throws a [BacnetDecodeException] if it is
  /// malformed.
  static List<BacnetDestination> listFromValue(BacnetValue value) {
    final items = value.asList;
    if (items.length % 7 != 0) {
      throw malformedConstruct('BACnetDestination', value);
    }
    return List.unmodifiable([
      for (var i = 0; i < items.length; i += 7)
        _fromFields(items.sublist(i, i + 7), value),
    ]);
  }

  static BacnetDestination _fromFields(
    List<BacnetValue> fields,
    Object source,
  ) {
    if (fields case [
      final BacnetBitString days,
      final BacnetTime from,
      final BacnetTime to,
      final recipient,
      BacnetUnsigned(value: final processId),
      BacnetBoolean(value: final confirmed),
      final BacnetBitString transitions,
    ]) {
      return BacnetDestination(
        validDays: BacnetDaysOfWeek.fromBitString(days),
        fromTime: from,
        toTime: to,
        recipient: _recipient(recipient, source),
        processId: processId,
        issueConfirmedNotifications: confirmed,
        transitions: BacnetEventTransitionBits.fromValue(transitions),
      );
    }
    throw malformedConstruct('BACnetDestination', source);
  }

  static BacnetRecipient _recipient(BacnetValue value, Object source) =>
      switch (value) {
        BacnetContextValue(tag: 0, :final data) => BacnetDeviceRecipient(
          constructPrimitive<BacnetObject>(
            data,
            BacnetApplicationTag.objectIdentifier,
            source,
          ).instance,
        ),
        BacnetConstructedValue(
          tag: 1,
          values: [
            BacnetUnsigned(value: final network),
            BacnetOctetString(value: final mac),
          ],
        ) =>
          BacnetAddressRecipient(network: network, mac: mac),
        _ => throw malformedConstruct('BACnetRecipient', source),
      };

  /// Builds the value of a Recipient_List.
  static BacnetValue listToValue(List<BacnetDestination> destinations) =>
      BacnetList([for (final d in destinations) ...d._fields]);

  /// The days notifications are sent.
  final BacnetDaysOfWeek validDays;

  /// Start of the daily window notifications are sent in.
  final BacnetTime fromTime;

  /// End of the daily window notifications are sent in.
  final BacnetTime toTime;

  /// The recipient.
  final BacnetRecipient recipient;

  /// Process identifier the notifications carry.
  final int processId;

  /// True to send ConfirmedEventNotifications, false for unconfirmed ones.
  final bool issueConfirmedNotifications;

  /// The transitions the recipient is notified about.
  final BacnetEventTransitionBits transitions;

  List<BacnetValue> get _fields => [
    validDays.toBitString(),
    fromTime,
    toTime,
    recipient.toValue(),
    BacnetUnsigned(processId),
    BacnetBoolean(issueConfirmedNotifications),
    transitions.toValue(),
  ];

  /// The value to write (one element of a Recipient_List).
  BacnetValue toValue() => BacnetList(_fields);

  @override
  bool operator ==(Object other) =>
      other is BacnetDestination &&
      other.validDays == validDays &&
      other.fromTime == fromTime &&
      other.toTime == toTime &&
      other.recipient == recipient &&
      other.processId == processId &&
      other.issueConfirmedNotifications == issueConfirmedNotifications &&
      other.transitions == transitions;

  @override
  int get hashCode => Object.hash(
    validDays,
    fromTime,
    toTime,
    recipient,
    processId,
    issueConfirmedNotifications,
    transitions,
  );

  @override
  String toString() =>
      'BacnetDestination($recipient, process $processId'
      '${issueConfirmedNotifications ? ', confirmed' : ''})';
}
