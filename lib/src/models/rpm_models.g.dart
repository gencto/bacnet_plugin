// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'rpm_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BacnetPropertyReference _$BacnetPropertyReferenceFromJson(
  Map<String, dynamic> json,
) => BacnetPropertyReference(
  propertyIdentifier: (json['propertyIdentifier'] as num).toInt(),
  propertyArrayIndex: (json['propertyArrayIndex'] as num?)?.toInt() ?? -1,
);

Map<String, dynamic> _$BacnetPropertyReferenceToJson(
  BacnetPropertyReference instance,
) => <String, dynamic>{
  'propertyIdentifier': instance.propertyIdentifier,
  'propertyArrayIndex': instance.propertyArrayIndex,
};

BacnetReadAccessSpecification _$BacnetReadAccessSpecificationFromJson(
  Map<String, dynamic> json,
) => BacnetReadAccessSpecification(
  objectIdentifier: BacnetObject.fromJson(
    json['objectIdentifier'] as Map<String, dynamic>,
  ),
  properties: (json['properties'] as List<dynamic>)
      .map((e) => BacnetPropertyReference.fromJson(e as Map<String, dynamic>))
      .toList(),
);

Map<String, dynamic> _$BacnetReadAccessSpecificationToJson(
  BacnetReadAccessSpecification instance,
) => <String, dynamic>{
  'objectIdentifier': instance.objectIdentifier,
  'properties': instance.properties,
};
