// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bacnet_object.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BacnetObject _$BacnetObjectFromJson(Map<String, dynamic> json) => BacnetObject(
  type: (json['type'] as num).toInt(),
  instance: (json['instance'] as num).toInt(),
  properties:
      (json['properties'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(int.parse(k), e),
      ) ??
      const {},
);

Map<String, dynamic> _$BacnetObjectToJson(
  BacnetObject instance,
) => <String, dynamic>{
  'type': instance.type,
  'instance': instance.instance,
  'properties': instance.properties.map((k, e) => MapEntry(k.toString(), e)),
};
