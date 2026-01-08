import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

part 'bacnet_object.g.dart';

/// Represents a BACnet object with its type, instance, and properties.
///
/// BACnet objects are the fundamental building blocks of BACnet devices.
/// Each object has a type (e.g., Analog Input, Binary Output) and a unique
/// instance number within that type.
///
/// Use [BacnetObjectType] constants for object types and [BacnetPropertyId]
/// constants for property identifiers.
///
/// Example:
/// ```dart
/// final sensor = BacnetObject(
///   type: BacnetObjectType.analogInput,
///   instance: 1,
///   properties: {
///     BacnetPropertyId.objectName: 'Temperature Sensor',
///     BacnetPropertyId.presentValue: 22.5,
///     BacnetPropertyId.units: 62, // degrees Celsius
///   },
/// );
///
/// print(sensor.name); // 'Temperature Sensor'
/// print(sensor.presentValue); // 22.5
/// ```
@immutable
@JsonSerializable()
class BacnetObject {
  /// Creates a BACnet object.
  ///
  /// [type] is the object type identifier.
  /// [instance] is the unique instance number for this object type.
  /// [properties] is an optional map of property IDs to values.
  const BacnetObject({
    required this.type,
    required this.instance,
    this.properties = const {},
  });

  /// The BACnet object type identifier.
  ///
  /// Use [BacnetObjectType] constants for standard object types.
  final int type;

  /// The unique instance number within this object type.
  final int instance;

  /// Map of property identifiers to their values.
  ///
  /// Keys are property IDs (use [BacnetPropertyId] constants).
  /// Values can be of any type depending on the property.
  final Map<int, dynamic> properties;

  /// Creates a BACnet object from JSON.
  factory BacnetObject.fromJson(Map<String, dynamic> json) =>
      _$BacnetObjectFromJson(json);

  /// Converts this object to JSON.
  Map<String, dynamic> toJson() => _$BacnetObjectToJson(this);

  /// Creates a copy of this object with updated values.
  ///
  /// Any parameters not specified will use the values from this object.
  BacnetObject copyWith({
    int? type,
    int? instance,
    Map<int, dynamic>? properties,
  }) {
    return BacnetObject(
      type: type ?? this.type,
      instance: instance ?? this.instance,
      properties: properties ?? this.properties,
    );
  }

  @override
  String toString() =>
      'BacnetObject(type: $type, instance: $instance, props: ${properties.length})';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BacnetObject &&
        other.type == type &&
        other.instance == instance;
  }

  @override
  int get hashCode => Object.hash(type, instance);

  /// Helper to get the Object Name property (Property ID 77).
  ///
  /// Returns null if the property is not set or is not a String.
  String? get name => properties[77] as String?;

  /// Helper to get the Present Value property (Property ID 85).
  ///
  /// Returns null if the property is not set.
  /// The type depends on the object type (e.g., double for Analog, bool for Binary).
  dynamic get presentValue => properties[85];

  /// Helper to get the Description property (Property ID 28).
  ///
  /// Returns null if the property is not set.
  String? get description => properties[28] as String?;

  /// Helper to get the Units property (Property ID 117).
  ///
  /// Returns null if the property is not set.
  /// The value is an engineering units enumeration.
  int? get units => properties[117] as int?;

  /// Helper to get the Out of Service property (Property ID 81).
  ///
  /// Returns null if the property is not set.
  /// When true, the object is not providing reliable data.
  bool? get outOfService => properties[81] as bool?;
}
