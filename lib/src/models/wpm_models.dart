/// @docImport '../constants/property_ids.dart';
library;

import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import '../constants/property_ids.dart';
import 'bacnet_value.dart';

part 'wpm_models.g.dart';

/// Represents a write access specification for a BACnet object.
///
/// Defines which object to write to and which properties to modify.
/// Used in WritePropertyMultiple requests to efficiently write multiple
/// properties in a single network transaction.
@immutable
@JsonSerializable(explicitToJson: true)
class BacnetWriteAccessSpecification {
  /// Creates a write access specification.
  ///
  /// [objectIdentifier] is the object to write to.
  /// [listOfProperties] is the list of property values to write.
  const BacnetWriteAccessSpecification({
    required this.objectIdentifier,
    required this.listOfProperties,
  });

  /// The BACnet object to write properties to.
  final BacnetObject objectIdentifier;

  /// List of property values to write to this object.
  final List<BacnetPropertyValue> listOfProperties;

  /// Creates a write access specification from JSON.
  factory BacnetWriteAccessSpecification.fromJson(Map<String, dynamic> json) =>
      _$BacnetWriteAccessSpecificationFromJson(json);

  /// Converts this specification to JSON.
  Map<String, dynamic> toJson() => _$BacnetWriteAccessSpecificationToJson(this);

  /// Former name of [toJson].
  @Deprecated('Use toJson')
  Map<String, dynamic> toMap() => toJson();

  /// Creates a copy of this specification with updated values.
  BacnetWriteAccessSpecification copyWith({
    BacnetObject? objectIdentifier,
    List<BacnetPropertyValue>? listOfProperties,
  }) {
    return BacnetWriteAccessSpecification(
      objectIdentifier: objectIdentifier ?? this.objectIdentifier,
      listOfProperties: listOfProperties ?? this.listOfProperties,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BacnetWriteAccessSpecification &&
        other.objectIdentifier == objectIdentifier &&
        other.listOfProperties.length == listOfProperties.length;
  }

  @override
  int get hashCode => Object.hash(objectIdentifier, listOfProperties.length);

  @override
  String toString() =>
      'BacnetWriteAccessSpec($objectIdentifier, ${listOfProperties.length} properties)';
}

/// Represents a property value to write in a WritePropertyMultiple request.
///
/// Specifies the property identifier, value, priority, and optional array index.
///
/// ```dart
/// const BacnetPropertyValue(
///   propertyIdentifier: BacnetPropertyId.presentValue,
///   value: BacnetReal(21.5),
///   priority: 8,
/// );
/// ```
@immutable
@JsonSerializable(explicitToJson: true)
class BacnetPropertyValue {
  /// Creates a property value for writing.
  ///
  /// [propertyIdentifier] is the property ID to write to.
  /// [value] is the value to write; its class decides the datatype.
  /// [propertyArrayIndex] is the optional array index (-1 for non-array properties).
  /// [priority] is the write priority (1-16, where 1 is highest).
  const BacnetPropertyValue({
    required this.propertyIdentifier,
    this.propertyArrayIndex = -1,
    required this.value,
    this.priority = 16,
  });

  /// The property identifier to write to.
  ///
  /// Use [BacnetPropertyId] constants for standard properties.
  final BacnetPropertyId propertyIdentifier;

  /// Optional array index for array properties.
  ///
  /// Set to -1 for non-array properties.
  /// Set to a specific index to write to one array element.
  final int propertyArrayIndex;

  /// The value to write, e.g. a [BacnetReal] for an analog present value
  /// or a [BacnetNull] to relinquish [priority].
  final BacnetValue value;

  /// Write priority (1-16).
  ///
  /// Lower numbers have higher priority. Priority 16 is the lowest (default).
  /// Used for commandable properties with priority arrays.
  final int priority;

  /// Creates a property value from JSON.
  factory BacnetPropertyValue.fromJson(Map<String, dynamic> json) =>
      _$BacnetPropertyValueFromJson(json);

  /// Converts this property value to JSON.
  Map<String, dynamic> toJson() => _$BacnetPropertyValueToJson(this);

  /// Former name of [toJson].
  @Deprecated('Use toJson')
  Map<String, dynamic> toMap() => toJson();

  /// Creates a copy of this property value with updated values.
  BacnetPropertyValue copyWith({
    BacnetPropertyId? propertyIdentifier,
    int? propertyArrayIndex,
    BacnetValue? value,
    int? priority,
  }) {
    return BacnetPropertyValue(
      propertyIdentifier: propertyIdentifier ?? this.propertyIdentifier,
      propertyArrayIndex: propertyArrayIndex ?? this.propertyArrayIndex,
      value: value ?? this.value,
      priority: priority ?? this.priority,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BacnetPropertyValue &&
        other.propertyIdentifier == propertyIdentifier &&
        other.propertyArrayIndex == propertyArrayIndex &&
        other.value == value &&
        other.priority == priority;
  }

  @override
  int get hashCode =>
      Object.hash(propertyIdentifier, propertyArrayIndex, value, priority);

  @override
  String toString() =>
      'PropertyValue($propertyIdentifier${propertyArrayIndex != -1 ? '[$propertyArrayIndex]' : ''} = $value @ priority $priority)';
}
