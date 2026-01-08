import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import 'bacnet_object.dart';

part 'device_metadata.g.dart';

/// Extended metadata for a BACnet device.
///
/// Contains detailed information about a device including
/// its object list and supported services.
///
/// Example:
/// ```dart
/// final metadata = DeviceMetadata(
///   deviceId: 1234,
///   objectCount: 42,
///   objects: [
///     BacnetObject(type: 0, instance: 1234),
///     BacnetObject(type: 2, instance: 0),
///   ],
///   supportedServices: [0, 12, 15],
/// );
/// ```
@immutable
@JsonSerializable()
class DeviceMetadata {
  /// Creates device metadata.
  const DeviceMetadata({
    required this.deviceId,
    required this.objectCount,
    this.objects = const [],
    this.supportedServices = const [],
  });

  /// The device instance number.
  final int deviceId;

  /// Total number of objects hosted by this device.
  final int objectCount;

  /// List of objects hosted by this device.
  ///
  /// May be partial if [objectCount] exceeds scan limits.
  final List<BacnetObject> objects;

  /// List of BACnet service choice numbers supported by this device.
  final List<int> supportedServices;

  /// Creates a copy of this metadata with updated values.
  DeviceMetadata copyWith({
    int? deviceId,
    int? objectCount,
    List<BacnetObject>? objects,
    List<int>? supportedServices,
  }) {
    return DeviceMetadata(
      deviceId: deviceId ?? this.deviceId,
      objectCount: objectCount ?? this.objectCount,
      objects: objects ?? this.objects,
      supportedServices: supportedServices ?? this.supportedServices,
    );
  }

  /// Creates DeviceMetadata from JSON.
  factory DeviceMetadata.fromJson(Map<String, dynamic> json) =>
      _$DeviceMetadataFromJson(json);

  /// Converts this metadata to JSON.
  Map<String, dynamic> toJson() => _$DeviceMetadataToJson(this);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DeviceMetadata &&
        other.deviceId == deviceId &&
        other.objectCount == objectCount;
  }

  @override
  int get hashCode => Object.hash(deviceId, objectCount);

  @override
  String toString() =>
      'DeviceMetadata(id: $deviceId, objectCount: $objectCount, objects: ${objects.length})';
}
