import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

part 'discovered_device.g.dart';

/// A BACnet device discovered on the network.
///
/// Contains device identification and network location information
/// obtained during device discovery (Who-Is/I-Am) and subsequent
/// property reads.
///
/// Example:
/// ```dart
/// final device = DiscoveredDevice(
///   deviceId: 1234,
///   vendorId: 123,
///   maxApduLength: 1476,
///   segmentationSupported: 3,
///   deviceName: 'Building Controller',
///   modelName: 'BACnet-100',
/// );
/// ```
@immutable
@JsonSerializable()
class DiscoveredDevice {
  /// Creates a discovered device.
  const DiscoveredDevice({
    required this.deviceId,
    required this.vendorId,
    required this.maxApduLength,
    required this.segmentationSupported,
    this.deviceName,
    this.description,
    this.location,
    this.modelName,
    this.vendorName,
    this.firmwareRevision,
    this.applicationSoftwareVersion,
    this.protocolVersion,
    this.protocolRevision,
  });

  /// The unique BACnet device instance number.
  final int deviceId;

  /// The vendor identifier (from BACnet vendor registry).
  final int vendorId;

  /// Maximum APDU length accepted by this device.
  final int maxApduLength;

  /// Segmentation support level (0-3).
  final int segmentationSupported;

  /// Human-readable device name.
  final String? deviceName;

  /// Device description.
  final String? description;

  /// Physical location of the device.
  final String? location;

  /// Model name/number.
  final String? modelName;

  /// Vendor name (resolved from vendor ID when possible).
  final String? vendorName;

  /// Firmware revision string.
  final String? firmwareRevision;

  /// Application software version.
  final String? applicationSoftwareVersion;

  /// BACnet protocol version (typically 1).
  final int? protocolVersion;

  /// BACnet protocol revision number.
  final int? protocolRevision;

  /// Creates a copy of this device with updated values.
  DiscoveredDevice copyWith({
    int? deviceId,
    int? vendorId,
    int? maxApduLength,
    int? segmentationSupported,
    String? deviceName,
    String? description,
    String? location,
    String? modelName,
    String? vendorName,
    String? firmwareRevision,
    String? applicationSoftwareVersion,
    int? protocolVersion,
    int? protocolRevision,
  }) {
    return DiscoveredDevice(
      deviceId: deviceId ?? this.deviceId,
      vendorId: vendorId ?? this.vendorId,
      maxApduLength: maxApduLength ?? this.maxApduLength,
      segmentationSupported:
          segmentationSupported ?? this.segmentationSupported,
      deviceName: deviceName ?? this.deviceName,
      description: description ?? this.description,
      location: location ?? this.location,
      modelName: modelName ?? this.modelName,
      vendorName: vendorName ?? this.vendorName,
      firmwareRevision: firmwareRevision ?? this.firmwareRevision,
      applicationSoftwareVersion:
          applicationSoftwareVersion ?? this.applicationSoftwareVersion,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      protocolRevision: protocolRevision ?? this.protocolRevision,
    );
  }

  /// Creates a DiscoveredDevice from JSON.
  factory DiscoveredDevice.fromJson(Map<String, dynamic> json) =>
      _$DiscoveredDeviceFromJson(json);

  /// Converts this device to JSON.
  Map<String, dynamic> toJson() => _$DiscoveredDeviceToJson(this);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DiscoveredDevice && other.deviceId == deviceId;
  }

  @override
  int get hashCode => deviceId.hashCode;

  @override
  String toString() =>
      'DiscoveredDevice(id: $deviceId, name: $deviceName, vendor: $vendorName)';
}
