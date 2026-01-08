import 'package:bacnet_plugin/src/models/bacnet_object.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

part 'wpm_models.g.dart';

/// Represents a write access specification for a BACnet object.
///
/// Defines which object to write to and which properties to modify.
/// Used in WritePropertyMultiple requests to efficiently write multiple
/// properties in a single network transaction.
@immutable
@JsonSerializable()
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

  /// Converts this specification to a Map (legacy compatibility).
  ///
  /// Prefer using [toJson] for new code.
  Map<String, dynamic> toMap() {
    return {
      'objectIdentifier': {
        'type': objectIdentifier.type,
        'instance': objectIdentifier.instance,
      },
      'listOfProperties': listOfProperties.map((p) => p.toMap()).toList(),
    };
  }

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
@immutable
@JsonSerializable()
class BacnetPropertyValue {
  /// Creates a property value for writing.
  ///
  /// [propertyIdentifier] is the property ID to write to.
  /// [value] is the value to write.
  /// [propertyArrayIndex] is the optional array index (-1 for non-array properties).
  /// [priority] is the write priority (1-16, where 1 is highest).
  const BacnetPropertyValue({
    required this.propertyIdentifier,
    this.propertyArrayIndex = -1,
    required this.value,
    this.priority = 16,
    this.tag =
        4, // Default to Real (4) or Unsigned (2)? Using 4 as placeholder.
  });

  /// The property identifier to write to.
  ///
  /// Use [BacnetPropertyId] constants for standard properties.
  final int propertyIdentifier;

  /// Optional array index for array properties.
  ///
  /// Set to -1 for non-array properties.
  /// Set to a specific index to write to one array element.
  final int propertyArrayIndex;

  /// The value to write.
  ///
  /// Type should match the property's data type (e.g., double for Analog, bool for Binary).
  final dynamic value;

  /// Write priority (1-16).
  ///
  /// Lower numbers have higher priority. Priority 16 is the lowest (default).
  /// Used for commandable properties with priority arrays.
  final int priority;

  /// BACnet application tag (e.g. 4 for Real, 2 for Unsigned).
  final int tag;

  /// Creates a property value from JSON.
  factory BacnetPropertyValue.fromJson(Map<String, dynamic> json) =>
      _$BacnetPropertyValueFromJson(json);

  /// Converts this property value to JSON.
  Map<String, dynamic> toJson() => _$BacnetPropertyValueToJson(this);

  /// Converts this property value to a Map (legacy compatibility).
  ///
  /// Prefer using [toJson] for new code.
  Map<String, dynamic> toMap() {
    return {
      'propertyIdentifier': propertyIdentifier,
      'propertyArrayIndex': propertyArrayIndex,
      'value': value,
      'priority': priority,
      'tag': tag,
    };
  }

  /// Creates a copy of this property value with updated values.
  BacnetPropertyValue copyWith({
    int? propertyIdentifier,
    int? propertyArrayIndex,
    dynamic value,
    int? priority,
    int? tag,
  }) {
    return BacnetPropertyValue(
      propertyIdentifier: propertyIdentifier ?? this.propertyIdentifier,
      propertyArrayIndex: propertyArrayIndex ?? this.propertyArrayIndex,
      value: value ?? this.value,
      priority: priority ?? this.priority,
      tag: tag ?? this.tag,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BacnetPropertyValue &&
        other.propertyIdentifier == propertyIdentifier &&
        other.propertyArrayIndex == propertyArrayIndex &&
        other.value == value &&
        other.priority == priority &&
        other.tag == tag;
  }

  @override
  int get hashCode =>
      Object.hash(propertyIdentifier, propertyArrayIndex, value, priority, tag);

  @override
  String toString() =>
      'PropertyValue($propertyIdentifier${propertyArrayIndex != -1 ? '[$propertyArrayIndex]' : ''} = $value @ priority $priority, tag $tag)';
}
