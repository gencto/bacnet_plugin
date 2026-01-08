import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import 'bacnet_object.dart';

part 'rpm_models.g.dart';

/// Represents a property reference in a BACnet ReadPropertyMultiple request.
///
/// Specifies which property (and optionally which array element) to read
/// from an object.
@immutable
@JsonSerializable()
class BacnetPropertyReference {
  /// Creates a property reference.
  ///
  /// [propertyIdentifier] is the property ID to read (use [BacnetPropertyId] constants).
  /// [propertyArrayIndex] is the optional array index (-1 for accessing the entire property).
  const BacnetPropertyReference({
    required this.propertyIdentifier,
    this.propertyArrayIndex = -1,
  });

  /// The property identifier to read.
  ///
  /// Use [BacnetPropertyId] constants for standard properties.
  final int propertyIdentifier;

  /// Optional array index for array properties.
  ///
  /// Set to -1 to read the entire property (not just one array element).
  /// Set to 0 to read the array length.
  /// Set to 1+ to read a specific array element.
  final int propertyArrayIndex;

  /// Creates a property reference from JSON.
  factory BacnetPropertyReference.fromJson(Map<String, dynamic> json) =>
      _$BacnetPropertyReferenceFromJson(json);

  /// Converts this reference to JSON.
  Map<String, dynamic> toJson() => _$BacnetPropertyReferenceToJson(this);

  /// Creates a copy of this reference with updated values.
  BacnetPropertyReference copyWith({
    int? propertyIdentifier,
    int? propertyArrayIndex,
  }) {
    return BacnetPropertyReference(
      propertyIdentifier: propertyIdentifier ?? this.propertyIdentifier,
      propertyArrayIndex: propertyArrayIndex ?? this.propertyArrayIndex,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BacnetPropertyReference &&
        other.propertyIdentifier == propertyIdentifier &&
        other.propertyArrayIndex == propertyArrayIndex;
  }

  @override
  int get hashCode => Object.hash(propertyIdentifier, propertyArrayIndex);

  @override
  String toString() =>
      'Property($propertyIdentifier${propertyArrayIndex != -1 ? '[$propertyArrayIndex]' : ''})';
}

/// Represents a read access specification for a BACnet object.
///
/// Defines which object to read from and which properties to retrieve.
/// Used in ReadPropertyMultiple requests to efficiently read multiple
/// properties in a single network transaction.
@immutable
@JsonSerializable()
class BacnetReadAccessSpecification {
  /// Creates a read access specification.
  ///
  /// [objectIdentifier] is the object to read from.
  /// [properties] is the list of properties to read from this object.
  const BacnetReadAccessSpecification({
    required this.objectIdentifier,
    required this.properties,
  });

  /// The BACnet object to read properties from.
  final BacnetObject objectIdentifier;

  /// List of property references specifying what to read.
  ///
  /// Each reference can specify a property ID and optional array index.
  final List<BacnetPropertyReference> properties;

  /// Creates a read access specification from JSON.
  factory BacnetReadAccessSpecification.fromJson(Map<String, dynamic> json) =>
      _$BacnetReadAccessSpecificationFromJson(json);

  /// Converts this specification to JSON.
  Map<String, dynamic> toJson() => _$BacnetReadAccessSpecificationToJson(this);

  /// Creates a copy of this specification with updated values.
  BacnetReadAccessSpecification copyWith({
    BacnetObject? objectIdentifier,
    List<BacnetPropertyReference>? properties,
  }) {
    return BacnetReadAccessSpecification(
      objectIdentifier: objectIdentifier ?? this.objectIdentifier,
      properties: properties ?? this.properties,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BacnetReadAccessSpecification &&
        other.objectIdentifier == objectIdentifier &&
        other.properties.length == properties.length;
  }

  @override
  int get hashCode => Object.hash(objectIdentifier, properties.length);

  @override
  String toString() => '$objectIdentifier: $properties';
}
