class ServerObject {
  final int objectType;
  final int instance;
  final String typeName;
  final Map<int, dynamic> properties;

  ServerObject({
    required this.objectType,
    required this.instance,
    required this.typeName,
    this.properties = const {},
  });

  String get displayName => '$typeName:$instance';

  static String getTypeName(int type) => switch (type) {
    0 => 'AI', // Analog Input
    1 => 'AO', // Analog Output
    2 => 'AV', // Analog Value
    3 => 'BI', // Binary Input
    4 => 'BV', // Binary Value
    5 => 'BO', // Binary Output
    _ => 'Type$type',
  };

  ServerObject copyWith({
    int? objectType,
    int? instance,
    String? typeName,
    Map<int, dynamic>? properties,
  }) {
    return ServerObject(
      objectType: objectType ?? this.objectType,
      instance: instance ?? this.instance,
      typeName: typeName ?? this.typeName,
      properties: properties ?? this.properties,
    );
  }
}
