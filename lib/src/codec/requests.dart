import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../models/bacnet_value.dart';
import '../models/rpm_models.dart';
import '../models/wpm_models.dart';
import 'value_encoding.dart';
import 'writer.dart';

/// Encodes a ReadProperty request.
Uint8List encodeReadProperty(
  int objectType,
  int instance,
  int propertyId, {
  int arrayIndex = -1,
}) {
  final w = BacnetWriter(16)
    ..ctxObjectId(0, objectType, instance)
    ..ctxUnsigned(1, propertyId);
  if (arrayIndex >= 0) w.ctxUnsigned(2, arrayIndex);
  return w.toBytes();
}

/// Encodes a ReadPropertyMultiple request.
Uint8List encodeReadPropertyMultiple(
  List<BacnetReadAccessSpecification> specs,
) {
  final w = BacnetWriter(32 + specs.length * 16);
  for (final spec in specs) {
    w
      ..ctxObjectId(
        0,
        spec.objectIdentifier.type,
        spec.objectIdentifier.instance,
      )
      ..opening(1);
    for (final property in spec.properties) {
      w.ctxUnsigned(0, property.propertyIdentifier);
      if (property.propertyArrayIndex >= 0) {
        w.ctxUnsigned(1, property.propertyArrayIndex);
      }
    }
    w.closing(1);
  }
  return w.toBytes();
}

/// Encodes a WriteProperty request.
Uint8List encodeWriteProperty(
  int objectType,
  int instance,
  int propertyId,
  BacnetValue value, {
  int arrayIndex = -1,
  int priority = 16,
}) {
  final w = BacnetWriter(32)
    ..ctxObjectId(0, objectType, instance)
    ..ctxUnsigned(1, propertyId);
  if (arrayIndex >= 0) w.ctxUnsigned(2, arrayIndex);
  w.opening(3);
  encodeApplicationValue(w, value);
  w.closing(3);
  if (priority >= 1 && priority < 16) w.ctxUnsigned(4, priority);
  return w.toBytes();
}

/// Encodes a WritePropertyMultiple request.
Uint8List encodeWritePropertyMultiple(
  List<BacnetWriteAccessSpecification> specs,
) {
  final w = BacnetWriter();
  for (final spec in specs) {
    final object = spec.objectIdentifier;
    w
      ..ctxObjectId(0, object.type, object.instance)
      ..opening(1);
    for (final property in spec.listOfProperties) {
      w.ctxUnsigned(0, property.propertyIdentifier);
      if (property.propertyArrayIndex >= 0) {
        w.ctxUnsigned(1, property.propertyArrayIndex);
      }
      w.opening(2);
      encodeApplicationValue(w, property.value);
      w.closing(2);
      if (property.priority >= 1 && property.priority < 16) {
        w.ctxUnsigned(3, property.priority);
      }
    }
    w.closing(1);
  }
  return w.toBytes();
}

/// Encodes a SubscribeCOV request. A [lifetime] of null with
/// [cancel] = true encodes a cancellation.
Uint8List encodeSubscribeCov({
  required int subscriberProcessId,
  required int objectType,
  required int instance,
  bool confirmed = false,
  int? lifetime,
  bool cancel = false,
}) {
  final w = BacnetWriter(24)
    ..ctxUnsigned(0, subscriberProcessId)
    ..ctxObjectId(1, objectType, instance);
  if (!cancel) {
    w.ctxBoolean(2, confirmed);
    w.ctxUnsigned(3, lifetime ?? 0);
  }
  return w.toBytes();
}

/// Encodes a SubscribeCOVProperty request.
Uint8List encodeSubscribeCovProperty({
  required int subscriberProcessId,
  required int objectType,
  required int instance,
  required int propertyId,
  int arrayIndex = -1,
  bool confirmed = false,
  int? lifetime,
  double? covIncrement,
  bool cancel = false,
}) {
  final w = BacnetWriter(32)
    ..ctxUnsigned(0, subscriberProcessId)
    ..ctxObjectId(1, objectType, instance);
  if (!cancel) {
    w.ctxBoolean(2, confirmed);
    w.ctxUnsigned(3, lifetime ?? 0);
  }
  w
    ..opening(4)
    ..ctxUnsigned(0, propertyId);
  if (arrayIndex >= 0) w.ctxUnsigned(1, arrayIndex);
  w.closing(4);
  if (covIncrement != null && !cancel) w.ctxReal(5, covIncrement);
  return w.toBytes();
}

/// The items of a list property to read with ReadRange (the Range choice
/// of ASHRAE 135 clause 15.8.1.1.4).
///
/// A negative `count` reads backwards from the reference item.
///
/// ```dart
/// // the newest 50 records of a log buffer with 1000 records
/// await client.readRange(1234, BacnetObjectType.trendLog, 1,
///     BacnetPropertyId.logBuffer,
///     range: const BacnetRange.byPosition(1000, -50));
/// ```
@immutable
sealed class BacnetRange {
  const BacnetRange();

  /// The whole list.
  const factory BacnetRange.all() = BacnetRangeAll;

  /// [count] items from position [index] (1 based).
  const factory BacnetRange.byPosition(int index, int count) =
      BacnetRangeByPosition;

  /// [count] records from sequence number [sequenceNumber] (log buffers).
  const factory BacnetRange.bySequenceNumber(int sequenceNumber, int count) =
      BacnetRangeBySequenceNumber;

  /// [count] records from the first one logged at or after [time] (log
  /// buffers; before [time] when [count] is negative).
  const factory BacnetRange.byTime(DateTime time, int count) =
      BacnetRangeByTime;
}

/// The whole list.
final class BacnetRangeAll extends BacnetRange {
  /// Creates the range.
  const BacnetRangeAll();
}

/// Items by position.
final class BacnetRangeByPosition extends BacnetRange {
  /// Creates the range.
  const BacnetRangeByPosition(this.index, this.count)
    : assert(index >= 1, 'positions start at 1');

  /// Position of the reference item (1 based).
  final int index;

  /// Number of items; negative reads backwards.
  final int count;
}

/// Log records by sequence number.
final class BacnetRangeBySequenceNumber extends BacnetRange {
  /// Creates the range.
  const BacnetRangeBySequenceNumber(this.sequenceNumber, this.count);

  /// Sequence number of the reference record.
  final int sequenceNumber;

  /// Number of records; negative reads backwards.
  final int count;
}

/// Log records by time.
final class BacnetRangeByTime extends BacnetRange {
  /// Creates the range.
  const BacnetRangeByTime(this.time, this.count);

  /// Reference time (device local time).
  final DateTime time;

  /// Number of records; negative reads backwards.
  final int count;
}

/// Encodes a ReadRange request.
Uint8List encodeReadRange(
  int objectType,
  int instance,
  int propertyId, {
  int arrayIndex = -1,
  BacnetRange range = const BacnetRangeAll(),
}) {
  final w = BacnetWriter(32)
    ..ctxObjectId(0, objectType, instance)
    ..ctxUnsigned(1, propertyId);
  if (arrayIndex >= 0) w.ctxUnsigned(2, arrayIndex);
  switch (range) {
    case BacnetRangeAll():
      break;
    case BacnetRangeByPosition(:final index, :final count):
      w
        ..opening(3)
        ..appUnsigned(index)
        ..appSigned(count)
        ..closing(3);
    case BacnetRangeBySequenceNumber(:final sequenceNumber, :final count):
      w
        ..opening(6)
        ..appUnsigned(sequenceNumber)
        ..appSigned(count)
        ..closing(6);
    case BacnetRangeByTime(:final time, :final count):
      w
        ..opening(7)
        ..appDate(BacnetDate.fromDateTime(time))
        ..appTime(BacnetTime.fromDateTime(time))
        ..appSigned(count)
        ..closing(7);
  }
  return w.toBytes();
}

/// Encodes a Who-Is request (both limits or none).
Uint8List encodeWhoIs({int? lowLimit, int? highLimit}) {
  if (lowLimit == null ||
      highLimit == null ||
      lowLimit < 0 ||
      highLimit < 0 ||
      lowLimit > BacnetObject.maxInstance ||
      highLimit > BacnetObject.maxInstance) {
    return Uint8List(0);
  }
  return (BacnetWriter(10)
        ..ctxUnsigned(0, lowLimit)
        ..ctxUnsigned(1, highLimit))
      .toBytes();
}

/// Encodes a (UTC)TimeSynchronization request.
Uint8List encodeTimeSynchronization(DateTime time) =>
    (BacnetWriter(10)
          ..appDate(BacnetDate.fromDateTime(time))
          ..appTime(BacnetTime.fromDateTime(time)))
        .toBytes();
