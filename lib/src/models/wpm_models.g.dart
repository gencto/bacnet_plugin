// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'wpm_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BacnetWriteAccessSpecification _$BacnetWriteAccessSpecificationFromJson(
  Map<String, dynamic> json,
) => BacnetWriteAccessSpecification(
  objectIdentifier: BacnetObject.fromJson(
    json['objectIdentifier'] as Map<String, dynamic>,
  ),
  listOfProperties: (json['listOfProperties'] as List<dynamic>)
      .map((e) => BacnetPropertyValue.fromJson(e as Map<String, dynamic>))
      .toList(),
);

Map<String, dynamic> _$BacnetWriteAccessSpecificationToJson(
  BacnetWriteAccessSpecification instance,
) => <String, dynamic>{
  'objectIdentifier': instance.objectIdentifier,
  'listOfProperties': instance.listOfProperties,
};

BacnetPropertyValue _$BacnetPropertyValueFromJson(Map<String, dynamic> json) =>
    BacnetPropertyValue(
      propertyIdentifier: (json['propertyIdentifier'] as num).toInt(),
      propertyArrayIndex: (json['propertyArrayIndex'] as num?)?.toInt() ?? -1,
      value: json['value'],
      priority: (json['priority'] as num?)?.toInt() ?? 16,
    );

Map<String, dynamic> _$BacnetPropertyValueToJson(
  BacnetPropertyValue instance,
) => <String, dynamic>{
  'propertyIdentifier': instance.propertyIdentifier,
  'propertyArrayIndex': instance.propertyArrayIndex,
  'value': instance.value,
  'priority': instance.priority,
};
