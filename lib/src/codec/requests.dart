import 'dart:typed_data';

import '../models/bacnet_object.dart';
import '../models/rpm_models.dart';
import '../models/wpm_models.dart';
import 'value_encoding.dart';
import 'values.dart';
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
  Object? value, {
  int? tag,
  int arrayIndex = -1,
  int priority = 16,
}) {
  final w = BacnetWriter(32)
    ..ctxObjectId(0, objectType, instance)
    ..ctxUnsigned(1, propertyId);
  if (arrayIndex >= 0) w.ctxUnsigned(2, arrayIndex);
  w.opening(3);
  _encodeObjectPropertyValue(w, objectType, propertyId, value, tag);
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
      _encodeObjectPropertyValue(
        w,
        object.type,
        property.propertyIdentifier,
        property.value,
        property.tag,
      );
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

/// ReadRange request types.
enum ReadRangeType {
  /// Read the whole list.
  all,

  /// By position (index, starting at 1).
  byPosition,

  /// By sequence number (log buffers).
  bySequenceNumber,

  /// By time (log buffers).
  byTime,
}

/// Encodes a ReadRange request.
///
/// For [ReadRangeType.byPosition] and [ReadRangeType.bySequenceNumber],
/// [reference] is the index/sequence number; for [ReadRangeType.byTime] it
/// is a [DateTime]. A negative [count] reads backwards from the reference.
Uint8List encodeReadRange(
  int objectType,
  int instance,
  int propertyId, {
  int arrayIndex = -1,
  ReadRangeType type = ReadRangeType.all,
  Object? reference,
  int count = 0,
}) {
  final w = BacnetWriter(32)
    ..ctxObjectId(0, objectType, instance)
    ..ctxUnsigned(1, propertyId);
  if (arrayIndex >= 0) w.ctxUnsigned(2, arrayIndex);
  switch (type) {
    case ReadRangeType.all:
      break;
    case ReadRangeType.byPosition:
      w
        ..opening(3)
        ..appUnsigned(coerceInt(reference ?? 1))
        ..appSigned(count)
        ..closing(3);
    case ReadRangeType.bySequenceNumber:
      w
        ..opening(6)
        ..appUnsigned(coerceInt(reference ?? 1))
        ..appSigned(count)
        ..closing(6);
    case ReadRangeType.byTime:
      final time = reference is DateTime ? reference : DateTime.now();
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

void _encodeObjectPropertyValue(
  BacnetWriter writer,
  int objectType,
  int propertyId,
  Object? value,
  int? tag,
) {
  encodeApplicationValue(
    writer,
    value,
    tag: tag ?? inferApplicationTag(objectType, propertyId, value),
  );
}
