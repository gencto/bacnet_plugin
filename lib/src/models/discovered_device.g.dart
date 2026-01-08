// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'discovered_device.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DiscoveredDevice _$DiscoveredDeviceFromJson(Map<String, dynamic> json) =>
    DiscoveredDevice(
      deviceId: (json['deviceId'] as num).toInt(),
      vendorId: (json['vendorId'] as num).toInt(),
      maxApduLength: (json['maxApduLength'] as num).toInt(),
      segmentationSupported: (json['segmentationSupported'] as num).toInt(),
      deviceName: json['deviceName'] as String?,
      description: json['description'] as String?,
      location: json['location'] as String?,
      modelName: json['modelName'] as String?,
      vendorName: json['vendorName'] as String?,
      firmwareRevision: json['firmwareRevision'] as String?,
      applicationSoftwareVersion: json['applicationSoftwareVersion'] as String?,
      protocolVersion: (json['protocolVersion'] as num?)?.toInt(),
      protocolRevision: (json['protocolRevision'] as num?)?.toInt(),
    );

Map<String, dynamic> _$DiscoveredDeviceToJson(DiscoveredDevice instance) =>
    <String, dynamic>{
      'deviceId': instance.deviceId,
      'vendorId': instance.vendorId,
      'maxApduLength': instance.maxApduLength,
      'segmentationSupported': instance.segmentationSupported,
      'deviceName': instance.deviceName,
      'description': instance.description,
      'location': instance.location,
      'modelName': instance.modelName,
      'vendorName': instance.vendorName,
      'firmwareRevision': instance.firmwareRevision,
      'applicationSoftwareVersion': instance.applicationSoftwareVersion,
      'protocolVersion': instance.protocolVersion,
      'protocolRevision': instance.protocolRevision,
    };
