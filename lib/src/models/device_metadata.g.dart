// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'device_metadata.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DeviceMetadata _$DeviceMetadataFromJson(Map<String, dynamic> json) =>
    DeviceMetadata(
      deviceId: (json['deviceId'] as num).toInt(),
      objectCount: (json['objectCount'] as num).toInt(),
      objects:
          (json['objects'] as List<dynamic>?)
              ?.map((e) => BacnetObject.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      supportedServices:
          (json['supportedServices'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [],
    );

Map<String, dynamic> _$DeviceMetadataToJson(DeviceMetadata instance) =>
    <String, dynamic>{
      'deviceId': instance.deviceId,
      'objectCount': instance.objectCount,
      'objects': instance.objects,
      'supportedServices': instance.supportedServices,
    };
