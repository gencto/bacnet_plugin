import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import '../core/types.dart';
import '../models/bacnet_object.dart';
import '../models/rpm_models.dart';
import '../models/trend_log_data.dart';
import '../models/wpm_models.dart';
import 'codec.dart';
import 'values.dart';

/// Converts a list of decoded property values into the value returned to
/// callers: `null` for no value, the value itself for exactly one value and
/// the list otherwise (arrays and lists).
Object? collapseValues(List<Object?> values) {
  if (values.isEmpty) return null;
  if (values.length == 1) return values.first;
  return List<Object?>.unmodifiable(values);
}

// ---------------------------------------------------------------------------
// Value encoding with datatype inference
// ---------------------------------------------------------------------------

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

/// Infers the application tag of [value] written to [propertyId] of an
/// object of [objectType]. Returns null when the Dart type decides.
int? inferApplicationTag(int objectType, int propertyId, Object? value) {
  if (value == null) return BacnetApplicationTag.nullValue;
  if (value is BacnetValue) return value.tag;
  if (propertyId == BacnetPropertyId.presentValue ||
      propertyId == BacnetPropertyId.relinquishDefault ||
      propertyId == BacnetPropertyId.feedbackValue) {
    switch (objectType) {
      case BacnetObjectType.analogInput:
      case BacnetObjectType.analogOutput:
      case BacnetObjectType.analogValue:
      case BacnetObjectType.loop:
      case BacnetObjectType.accumulator:
        if (value is num) return BacnetApplicationTag.real;
      case BacnetObjectType.binaryInput:
      case BacnetObjectType.binaryOutput:
      case BacnetObjectType.binaryValue:
      case BacnetObjectType.binaryLightingOutput:
        if (value is num || value is bool) {
          return BacnetApplicationTag.enumerated;
        }
      case BacnetObjectType.multiStateInput:
      case BacnetObjectType.multiStateOutput:
      case BacnetObjectType.multiStateValue:
      case BacnetObjectType.positiveIntegerValue:
        if (value is num) return BacnetApplicationTag.unsignedInt;
      case BacnetObjectType.integerValue:
        if (value is num) return BacnetApplicationTag.signedInt;
      case BacnetObjectType.largeAnalogValue:
        if (value is num) return BacnetApplicationTag.doubleValue;
      case BacnetObjectType.lightingOutput:
        if (value is num) return BacnetApplicationTag.real;
    }
  }
  if (value is num && _realProperties.contains(propertyId)) {
    return BacnetApplicationTag.real;
  }
  if ((value is int || value is bool) &&
      _enumeratedProperties.contains(propertyId)) {
    return BacnetApplicationTag.enumerated;
  }
  return null;
}

/// Encodes one value as application tagged data.
///
/// [tag] forces the BACnet datatype (see [BacnetApplicationTag]); without it
/// the type follows the Dart value: `null` → Null, [bool] → Boolean,
/// [int] → Unsigned (Signed when negative), [double] → Real, [String] →
/// CharacterString, [BacnetObject] → ObjectIdentifier, [BacnetDate],
/// [BacnetTime], [BacnetBitString], [Uint8List] → OctetString and a [List]
/// encodes each element.
void encodeApplicationValue(BacnetWriter writer, Object? value, {int? tag}) {
  if (value is BacnetValue) {
    encodeApplicationValue(writer, value.value, tag: value.tag);
    return;
  }
  if (tag == null) {
    switch (value) {
      case null:
        writer.appNull();
      case bool v:
        writer.appBoolean(v);
      case int v:
        if (v < 0) {
          writer.appSigned(v);
        } else {
          writer.appUnsigned(v);
        }
      case double v:
        writer.appReal(v);
      case String v:
        writer.appCharacterString(v);
      case BacnetObject v:
        writer.appObjectId(v.type, v.instance);
      case BacnetDate v:
        writer.appDate(v);
      case BacnetTime v:
        writer.appTime(v);
      case BacnetBitString v:
        writer.appBitString(v);
      case Uint8List v:
        writer.appOctetString(v);
      case List<Object?> v:
        for (final item in v) {
          encodeApplicationValue(writer, item);
        }
      default:
        throw BacnetEncodeException(
          'cannot infer BACnet datatype of ${value.runtimeType}',
        );
    }
    return;
  }
  if (value is List &&
      value is! Uint8List &&
      tag != BacnetApplicationTag.bitString) {
    for (final item in value) {
      encodeApplicationValue(writer, item, tag: tag);
    }
    return;
  }
  switch (tag) {
    case BacnetApplicationTag.nullValue:
      writer.appNull();
    case BacnetApplicationTag.boolean:
      writer.appBoolean(value is bool ? value : _as<num>(value, tag) != 0);
    case BacnetApplicationTag.unsignedInt:
      writer.appUnsigned(_toInt(value));
    case BacnetApplicationTag.signedInt:
      writer.appSigned(_toInt(value));
    case BacnetApplicationTag.real:
      writer.appReal(_as<num>(value, tag).toDouble());
    case BacnetApplicationTag.doubleValue:
      writer.appDouble(_as<num>(value, tag).toDouble());
    case BacnetApplicationTag.octetString:
      writer.appOctetString(_as<List<int>>(value, tag));
    case BacnetApplicationTag.characterString:
      writer.appCharacterString(value.toString());
    case BacnetApplicationTag.bitString:
      writer.appBitString(
        value is BacnetBitString
            ? value
            : BacnetBitString(List<bool>.from(_as<List<Object?>>(value, tag))),
      );
    case BacnetApplicationTag.enumerated:
      writer.appEnumerated(_toInt(value));
    case BacnetApplicationTag.date:
      writer.appDate(
        value is DateTime
            ? BacnetDate.fromDateTime(value)
            : _as<BacnetDate>(value, tag),
      );
    case BacnetApplicationTag.time:
      writer.appTime(
        value is DateTime
            ? BacnetTime.fromDateTime(value)
            : _as<BacnetTime>(value, tag),
      );
    case BacnetApplicationTag.objectIdentifier:
      final object = _as<BacnetObject>(value, tag);
      writer.appObjectId(object.type, object.instance);
    default:
      throw BacnetEncodeException('unsupported application tag $tag');
  }
}

T _as<T>(Object? value, int tag) {
  if (value is T) return value;
  throw BacnetEncodeException(
    'value $value (${value.runtimeType}) does not match application tag $tag',
  );
}

int _toInt(Object? value) {
  if (value is bool) return value ? 1 : 0;
  if (value is int) return value;
  if (value is double && value == value.truncateToDouble()) {
    return value.toInt();
  }
  throw BacnetEncodeException('expected an integer, got $value');
}

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

// ---------------------------------------------------------------------------
// Request encoders
// ---------------------------------------------------------------------------

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
  final w = BacnetWriter(64);
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
        ..appUnsigned(_toInt(reference ?? 1))
        ..appSigned(count)
        ..closing(3);
    case ReadRangeType.bySequenceNumber:
      w
        ..opening(6)
        ..appUnsigned(_toInt(reference ?? 1))
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

// ---------------------------------------------------------------------------
// Decoders
// ---------------------------------------------------------------------------

/// Decoded ReadProperty-ACK.
@immutable
class ReadPropertyResult {
  /// Creates a result.
  const ReadPropertyResult({
    required this.object,
    required this.propertyId,
    required this.arrayIndex,
    required this.values,
  });

  /// Object that was read.
  final BacnetObject object;

  /// Property that was read.
  final int propertyId;

  /// Array index or -1.
  final int arrayIndex;

  /// Decoded values.
  final List<Object?> values;

  /// Collapsed value (see [collapseValues]).
  Object? get value => collapseValues(values);
}

/// Decodes a ReadProperty-ACK.
ReadPropertyResult decodeReadPropertyAck(Uint8List data) {
  final r = BacnetReader(data);
  final object = r.readContextObjectId(0);
  final propertyId = r.readContextUnsigned(1);
  final arrayIndex = r.readOptionalContextUnsigned(2) ?? -1;
  r.expectOpening(3);
  final values = r.readValuesUntilClosing(3);
  return ReadPropertyResult(
    object: object,
    propertyId: propertyId,
    arrayIndex: arrayIndex,
    values: values,
  );
}

/// Decodes a ReadPropertyMultiple-ACK into `'type:instance'` →
/// `propertyId` → value (a [BacnetError] for property access errors).
Map<String, Map<int, dynamic>> decodeReadPropertyMultipleAck(Uint8List data) {
  final r = BacnetReader(data);
  final result = <String, Map<int, dynamic>>{};
  while (!r.isAtEnd) {
    final object = r.readContextObjectId(0);
    final properties = <int, dynamic>{};
    r.expectOpening(1);
    while (!r.nextIsClosing(1)) {
      final propertyId = r.readContextUnsigned(2);
      r.readOptionalContextUnsigned(3);
      if (r.nextIsOpening(4)) {
        r.expectOpening(4);
        properties[propertyId] = collapseValues(r.readValuesUntilClosing(4));
      } else {
        r.expectOpening(5);
        final errorClass = r.readApplicationValue();
        final errorCode = r.readApplicationValue();
        r.expectClosing(5);
        properties[propertyId] = BacnetError(
          errorClass is int ? errorClass : -1,
          errorCode is int ? errorCode : -1,
        );
      }
    }
    r.expectClosing(1);
    result['${object.type}:${object.instance}'] = properties;
  }
  return result;
}

/// Decoded ReadRange-ACK.
@immutable
class ReadRangeResult {
  /// Creates a result.
  const ReadRangeResult({
    required this.object,
    required this.propertyId,
    required this.resultFlags,
    required this.itemCount,
    required this.items,
    this.firstSequenceNumber,
  });

  /// Object that was read.
  final BacnetObject object;

  /// Property that was read.
  final int propertyId;

  /// Result flags: bit 0 first-item, bit 1 last-item, bit 2 more-items.
  final BacnetBitString resultFlags;

  /// Number of returned items.
  final int itemCount;

  /// Decoded items (application values or constructed records).
  final List<Object?> items;

  /// Sequence number of the first item (log buffers only).
  final int? firstSequenceNumber;

  /// True when more items are available.
  bool get moreItems => resultFlags[2];
}

/// Decodes a ReadRange-ACK.
ReadRangeResult decodeReadRangeAck(Uint8List data) {
  final r = BacnetReader(data);
  final object = r.readContextObjectId(0);
  final propertyId = r.readContextUnsigned(1);
  r.readOptionalContextUnsigned(2);
  final flags = r.readContextBitString(3);
  final count = r.readContextUnsigned(4);
  var items = const <Object?>[];
  if (r.nextIsOpening(5)) {
    r.expectOpening(5);
    items = r.readValuesUntilClosing(5);
  }
  final firstSequence = r.readOptionalContextUnsigned(6);
  return ReadRangeResult(
    object: object,
    propertyId: propertyId,
    resultFlags: flags,
    itemCount: count,
    items: items,
    firstSequenceNumber: firstSequence,
  );
}

/// Converts ReadRange items of a Trend Log `log-buffer` into entries.
///
/// Every BACnetLogRecord is three consecutive items: the timestamp
/// (constructed [0]), the log datum (constructed [1]) and optional status
/// flags (context [2]).
List<TrendLogEntry> decodeLogRecords(List<Object?> items) {
  final entries = <TrendLogEntry>[];
  DateTime? timestamp;
  Object? datum;
  var hasDatum = false;
  String status = 'OK';

  void flush() {
    if (timestamp != null && hasDatum) {
      entries.add(
        TrendLogEntry(timestamp: timestamp!, value: datum, status: status),
      );
    }
    timestamp = null;
    datum = null;
    hasDatum = false;
    status = 'OK';
  }

  for (final item in items) {
    if (item is BacnetConstructedValue && item.tag == 0) {
      flush();
      final date = item.values.whereType<BacnetDate>().firstOrNull;
      final time = item.values.whereType<BacnetTime>().firstOrNull;
      final day = date?.toDateTime();
      timestamp = day == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : day.add(time?.toDuration() ?? Duration.zero);
    } else if (item is BacnetConstructedValue && item.tag == 1) {
      hasDatum = true;
      datum = _decodeLogDatum(item.values.isEmpty ? null : item.values.first);
    } else if (item is BacnetContextValue && item.tag == 2) {
      status = BacnetStatusFlags.fromBitString(
        BacnetReader.bitStringFrom(item.data),
      ).toString();
    }
  }
  flush();
  return entries;
}

Object? _decodeLogDatum(Object? choice) {
  if (choice is BacnetContextValue) {
    final bytes = choice.data;
    switch (choice.tag) {
      case 0: // log-status
        return BacnetReader.bitStringFrom(bytes);
      case 1: // boolean
        return bytes.isNotEmpty && bytes[0] != 0;
      case 2: // real
      case 9: // time-change
        return BacnetReader.realFrom(bytes);
      case 3: // enumerated
      case 4: // unsigned
        return BacnetReader.unsignedFrom(bytes);
      case 5: // signed
        return BacnetReader.signedFrom(bytes);
      case 6: // bit string
        return BacnetReader.bitStringFrom(bytes);
      case 7: // null
        return null;
    }
    return choice;
  }
  if (choice is BacnetConstructedValue) {
    if (choice.tag == 8 && choice.values.length >= 2) {
      // failure: BACnetError
      final errorClass = choice.values[0];
      final errorCode = choice.values[1];
      return BacnetError(
        errorClass is int ? errorClass : -1,
        errorCode is int ? errorCode : -1,
      );
    }
    // any-value
    return collapseValues(choice.values);
  }
  return choice;
}

/// One property value of a COV notification.
@immutable
class CovPropertyValue {
  /// Creates a COV property value.
  const CovPropertyValue({
    required this.propertyId,
    required this.value,
    this.arrayIndex = -1,
    this.priority,
  });

  /// Property identifier.
  final int propertyId;

  /// Array index or -1.
  final int arrayIndex;

  /// Decoded value.
  final Object? value;

  /// Priority, if present.
  final int? priority;
}

/// Decoded COV notification.
@immutable
class CovNotificationData {
  /// Creates a COV notification.
  const CovNotificationData({
    required this.subscriberProcessId,
    required this.initiatingDeviceId,
    required this.monitoredObject,
    required this.timeRemaining,
    required this.values,
  });

  /// Subscriber process identifier of the subscription.
  final int subscriberProcessId;

  /// Device that sent the notification.
  final int initiatingDeviceId;

  /// Monitored object.
  final BacnetObject monitoredObject;

  /// Remaining subscription lifetime in seconds.
  final int timeRemaining;

  /// Reported values.
  final List<CovPropertyValue> values;
}

/// Decodes a (Un)ConfirmedCOVNotification request.
CovNotificationData decodeCovNotification(Uint8List data) {
  final r = BacnetReader(data);
  final pid = r.readContextUnsigned(0);
  final device = r.readContextObjectId(1);
  final object = r.readContextObjectId(2);
  final timeRemaining = r.readContextUnsigned(3);
  r.expectOpening(4);
  final values = <CovPropertyValue>[];
  while (!r.nextIsClosing(4)) {
    final propertyId = r.readContextUnsigned(0);
    final arrayIndex = r.readOptionalContextUnsigned(1) ?? -1;
    r.expectOpening(2);
    final value = collapseValues(r.readValuesUntilClosing(2));
    final priority = r.readOptionalContextUnsigned(3);
    values.add(
      CovPropertyValue(
        propertyId: propertyId,
        arrayIndex: arrayIndex,
        value: value,
        priority: priority,
      ),
    );
  }
  r.expectClosing(4);
  return CovNotificationData(
    subscriberProcessId: pid,
    initiatingDeviceId: device.instance,
    monitoredObject: object,
    timeRemaining: timeRemaining,
    values: values,
  );
}

/// Extracts error class and code from a complex Error PDU payload
/// (e.g. WritePropertyMultiple-Error, CreateObject-Error).
(int, int) decodeComplexError(Uint8List data) {
  final r = BacnetReader(data);
  final wrapped = r.nextIsOpening(0);
  if (wrapped) r.expectOpening(0);
  final errorClass = r.readApplicationValue();
  final errorCode = r.readApplicationValue();
  return (
    errorClass is int ? errorClass : -1,
    errorCode is int ? errorCode : -1,
  );
}

/// Decodes a property value encoded as application data (server writes).
Object? decodeApplicationData(Uint8List data) {
  if (data.isEmpty) return null;
  final r = BacnetReader(data);
  final values = <Object?>[];
  while (!r.isAtEnd) {
    values.add(r.readAnyValue());
  }
  return collapseValues(values);
}
