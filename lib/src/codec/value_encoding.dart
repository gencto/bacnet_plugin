import 'dart:typed_data';

import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import '../models/bacnet_object.dart';
import 'reader.dart';
import 'values.dart';
import 'writer.dart';

/// Converts a list of decoded property values into the value returned to
/// callers: `null` for no value, the value itself for exactly one value and
/// the list otherwise (arrays and lists).
Object? collapseValues(List<Object?> values) {
  if (values.isEmpty) return null;
  if (values.length == 1) return values.first;
  return List<Object?>.unmodifiable(values);
}

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
      case final bool v:
        writer.appBoolean(v);
      case final int v:
        if (v < 0) {
          writer.appSigned(v);
        } else {
          writer.appUnsigned(v);
        }
      case final double v:
        writer.appReal(v);
      case final String v:
        writer.appCharacterString(v);
      case final BacnetObject v:
        writer.appObjectId(v.type, v.instance);
      case final BacnetDate v:
        writer.appDate(v);
      case final BacnetTime v:
        writer.appTime(v);
      case final BacnetBitString v:
        writer.appBitString(v);
      case final Uint8List v:
        writer.appOctetString(v);
      case final List<Object?> v:
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
      writer.appUnsigned(coerceInt(value));
    case BacnetApplicationTag.signedInt:
      writer.appSigned(coerceInt(value));
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
      writer.appEnumerated(coerceInt(value));
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

/// Converts integral values (and booleans) to [int] for integer tags.
int coerceInt(Object? value) {
  if (value is bool) return value ? 1 : 0;
  if (value is int) return value;
  if (value is double && value == value.truncateToDouble()) {
    return value.toInt();
  }
  throw BacnetEncodeException('expected an integer, got $value');
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
