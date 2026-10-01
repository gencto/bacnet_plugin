import 'dart:typed_data';

import '../core/exceptions.dart';
import '../models/bacnet_value.dart';
import 'reader.dart';
import 'writer.dart';

/// Converts the values of one property into the value returned to callers:
/// the value itself for exactly one value, a [BacnetList] otherwise (arrays
/// and lists, including empty ones).
BacnetValue collapseValues(List<BacnetValue> values) {
  if (values.length == 1) return values.first;
  return BacnetList(List.unmodifiable(values));
}

/// Encodes [value] as application tagged data (the elements of a
/// [BacnetList] one after another).
void encodeApplicationValue(BacnetWriter writer, BacnetValue value) {
  switch (value) {
    case BacnetNull():
      writer.appNull();
    case BacnetBoolean(:final value):
      writer.appBoolean(value);
    case BacnetUnsigned(:final value):
      writer.appUnsigned(value);
    case BacnetSigned(:final value):
      writer.appSigned(value);
    case BacnetReal(:final value):
      writer.appReal(value);
    case BacnetDouble(:final value):
      writer.appDouble(value);
    case BacnetOctetString(:final value):
      writer.appOctetString(value);
    case BacnetCharacterString(:final value):
      writer.appCharacterString(value);
    case final BacnetBitString value:
      writer.appBitString(value);
    case BacnetEnumerated(:final value):
      writer.appEnumerated(value);
    case final BacnetDate value:
      writer.appDate(value);
    case final BacnetTime value:
      writer.appTime(value);
    case BacnetObject(:final type, :final instance):
      writer.appObjectId(type, instance);
    case BacnetList(:final items):
      for (final item in items) {
        encodeApplicationValue(writer, item);
      }
    case BacnetConstructedValue(:final tag, :final values):
      writer.opening(tag);
      for (final item in values) {
        encodeApplicationValue(writer, item);
      }
      writer.closing(tag);
    case BacnetContextValue(:final tag, :final data):
      writer.ctxRaw(tag, data);
  }
}

/// Encodes a primitive [value] with context tag [tag], the form fields of
/// constructed datatypes take (the inverse of [BacnetReader.primitiveFrom]).
BacnetContextValue contextValue(int tag, BacnetValue value) {
  if (value case BacnetBoolean(:final value)) {
    return BacnetContextValue(tag, Uint8List.fromList([if (value) 1 else 0]));
  }
  final writer = BacnetWriter(16);
  encodeApplicationValue(writer, value);
  final encoded = writer.toBytes();
  final reader = BacnetReader(encoded);
  final header = reader.readTag();
  if (header.isContext || reader.remaining != header.length) {
    throw BacnetEncodeException('$value is not a primitive value');
  }
  return BacnetContextValue(tag, Uint8List.sublistView(encoded, reader.offset));
}

/// Decodes a property value encoded as application data (server reads and
/// writes).
BacnetValue decodeApplicationData(Uint8List data) {
  final r = BacnetReader(data);
  final values = <BacnetValue>[];
  while (!r.isAtEnd) {
    values.add(r.readAnyValue());
  }
  return collapseValues(values);
}
