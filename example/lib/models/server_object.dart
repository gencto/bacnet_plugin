import 'package:bacnet_plugin/bacnet_plugin.dart';

class ServerObject {
  ServerObject({required this.objectType, required this.instance});

  final BacnetObjectType objectType;
  final int instance;

  String get typeName => objectType.label;

  String get displayName => '$typeName:$instance';

  ServerObject copyWith({BacnetObjectType? objectType, int? instance}) {
    return ServerObject(
      objectType: objectType ?? this.objectType,
      instance: instance ?? this.instance,
    );
  }
}
