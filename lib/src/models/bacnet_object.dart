import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import '../constants/engineering_units.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';

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
///     BacnetPropertyId.units: BacnetEngineeringUnits.degreesCelsius,
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

  /// Largest object instance number (also the "unconfigured" wildcard).
  static const int maxInstance = 4194303;

  /// The BACnet object type.
  final BacnetObjectType type;

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
    BacnetObjectType? type,
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

  /// The Object Name property, if read and a String.
  String? get name => _property<String>(BacnetPropertyId.objectName);

  /// The Present Value property, if read. The type depends on the object
  /// type (e.g. double for analog, int for binary and multi-state objects).
  dynamic get presentValue => properties[BacnetPropertyId.presentValue];

  /// The Description property, if read and a String.
  String? get description => _property<String>(BacnetPropertyId.description);

  /// The Units property, if read.
  BacnetEngineeringUnits? get units =>
      switch (properties[BacnetPropertyId.units]) {
        final int units => BacnetEngineeringUnits(units),
        _ => null,
      };

  /// The Out Of Service property, if read. When true the object does not
  /// provide reliable data.
  bool? get outOfService => _property<bool>(BacnetPropertyId.outOfService);

  T? _property<T>(BacnetPropertyId id) => switch (properties[id]) {
    final T value => value,
    _ => null,
  };
}
