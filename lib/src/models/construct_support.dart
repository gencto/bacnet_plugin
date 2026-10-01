import 'dart:typed_data';

import '../codec/reader.dart';
import '../core/exceptions.dart';
import 'bacnet_value.dart';

// Helpers of the typed constructed datatypes (not exported).

/// Decodes the content of a context tagged field as application datatype
/// [applicationTag] and checks that it is a [T].
T constructPrimitive<T extends BacnetValue>(
  Uint8List content,
  int applicationTag,
  Object source,
) {
  try {
    if (BacnetReader.primitiveFrom(content, applicationTag) case final T v) {
      return v;
    }
  } on BacnetDecodeException {
    // reported below with the construct
  }
  throw malformedConstruct('field of application tag $applicationTag', source);
}

/// The exception for a value that is not a valid [what].
BacnetDecodeException malformedConstruct(String what, Object value) =>
    BacnetDecodeException('malformed $what: $value');

/// Element-wise equality of two lists.
bool listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Reads the context tagged fields of a constructed datatype in order.
///
/// Every read throws a [BacnetDecodeException] naming the construct when the next
/// field is missing or of another datatype; fields after the last one read
/// are ignored (later revisions of the standard append fields).
final class ConstructFields {
  /// Reads `items`, the fields of the `what` `source`.
  ConstructFields(this._items, this._what, this._source);

  final List<BacnetValue> _items;
  final String _what;
  final Object _source;
  int _index = 0;

  BacnetValue? get _next => _index < _items.length ? _items[_index] : null;

  /// True when the next field has context tag [tag].
  bool has(int tag) => switch (_next) {
    BacnetContextValue(tag: final t) ||
    BacnetConstructedValue(tag: final t) => t == tag,
    _ => false,
  };

  /// The primitive field [tag] decoded as application datatype
  /// [applicationTag].
  T primitive<T extends BacnetValue>(int tag, int applicationTag) {
    if (_next case BacnetContextValue(
      tag: final t,
      :final data,
    ) when t == tag) {
      _index++;
      return constructPrimitive<T>(data, applicationTag, _source);
    }
    throw malformedConstruct(_what, _source);
  }

  /// The values of the constructed field [tag].
  List<BacnetValue> constructed(int tag) {
    if (_next case BacnetConstructedValue(
      tag: final t,
      :final values,
    ) when t == tag) {
      _index++;
      return values;
    }
    throw malformedConstruct(_what, _source);
  }

  /// The single value of the constructed field [tag] (a CHOICE).
  BacnetValue choice(int tag) => switch (constructed(tag)) {
    [final value] => value,
    _ => throw malformedConstruct(_what, _source),
  };

  /// An Unsigned field.
  int unsigned(int tag) =>
      primitive<BacnetUnsigned>(tag, BacnetApplicationTag.unsignedInt).value;

  /// An INTEGER field.
  int signed(int tag) =>
      primitive<BacnetSigned>(tag, BacnetApplicationTag.signedInt).value;

  /// An ENUMERATED field.
  int enumerated(int tag) =>
      primitive<BacnetEnumerated>(tag, BacnetApplicationTag.enumerated).value;

  /// A REAL field.
  double real(int tag) =>
      primitive<BacnetReal>(tag, BacnetApplicationTag.real).value;

  /// A Double field.
  double doubleValue(int tag) =>
      primitive<BacnetDouble>(tag, BacnetApplicationTag.doubleValue).value;

  /// A BOOLEAN field.
  bool boolean(int tag) =>
      primitive<BacnetBoolean>(tag, BacnetApplicationTag.boolean).value;

  /// A CharacterString field.
  String characterString(int tag) => primitive<BacnetCharacterString>(
    tag,
    BacnetApplicationTag.characterString,
  ).value;

  /// A BIT STRING field.
  BacnetBitString bitString(int tag) =>
      primitive<BacnetBitString>(tag, BacnetApplicationTag.bitString);

  /// A BACnetObjectIdentifier field.
  BacnetObject objectId(int tag) =>
      primitive<BacnetObject>(tag, BacnetApplicationTag.objectIdentifier);

  /// A BACnetStatusFlags field.
  BacnetStatusFlags statusFlags(int tag) =>
      BacnetStatusFlags.fromBitString(bitString(tag));
}
