import 'package:bacnet_plugin/bacnet_plugin.dart';

class ServerObject {
  ServerObject({
    required this.objectType,
    required this.instance,
    this.properties = const {},
  });

  final BacnetObjectType objectType;
  final int instance;
  final Map<int, dynamic> properties;

  String get typeName => objectType.label;

  String get displayName => '$typeName:$instance';

  ServerObject copyWith({
    BacnetObjectType? objectType,
    int? instance,
    Map<int, dynamic>? properties,
  }) {
    return ServerObject(
      objectType: objectType ?? this.objectType,
      instance: instance ?? this.instance,
      properties: properties ?? this.properties,
    );
  }
}
