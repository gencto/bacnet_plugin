/// @docImport '../utilities/device_description.dart';
library;

import 'package:meta/meta.dart';

import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import 'bacnet_value.dart';
import 'epics_format.dart';

/// Everything a device tells about itself: the properties of all its
/// objects, read by [BacnetDeviceDescriptions.describeDevice].
///
/// [toJson] and [BacnetDeviceDescription.fromJson] store it (e.g. to compare
/// a device with an earlier state), [toEpics] lists it in the style of the
/// object list of an EPICS (ASHRAE 135.1 Annex A):
///
/// ```dart
/// final description = await client.describeDevice(1234);
/// await File('ahu-1.json').writeAsString(jsonEncode(description.toJson()));
/// await File('ahu-1.tpi').writeAsString(description.toEpics());
/// ```
@immutable
final class BacnetDeviceDescription {
  /// Creates a description.
  BacnetDeviceDescription({
    required this.deviceId,
    required this.time,
    required Map<BacnetObject, Map<BacnetPropertyId, BacnetValue>> objects,
  }) : objects = Map.unmodifiable({
         for (final MapEntry(key: object, value: properties) in objects.entries)
           object: Map<BacnetPropertyId, BacnetValue>.unmodifiable(properties),
       });

  /// Reads a description stored with [toJson].
  factory BacnetDeviceDescription.fromJson(Map<String, Object?> json) {
    final deviceId = json['deviceId'];
    final time = json['time'];
    final objects = json['objects'];
    if (deviceId is! int || time is! String || objects is! List) {
      throw const FormatException('not a BACnet device description');
    }
    final result = <BacnetObject, Map<BacnetPropertyId, BacnetValue>>{};
    for (final object in objects) {
      if (object case {
        'type': final int type,
        'instance': final int instance,
        'properties': final List<Object?> properties,
      }) {
        result[BacnetObject(
          type: BacnetObjectType(type),
          instance: instance,
        )] = Map.fromEntries([
          for (final property in properties)
            switch (property) {
              {'id': final int id, 'value': final Map<String, Object?> value} =>
                MapEntry(BacnetPropertyId(id), BacnetValue.fromJson(value)),
              _ => throw const FormatException('malformed property'),
            },
        ]);
      } else {
        throw const FormatException('malformed object');
      }
    }
    return BacnetDeviceDescription(
      deviceId: deviceId,
      time: DateTime.parse(time),
      objects: result,
    );
  }

  /// The device.
  final int deviceId;

  /// When the device was read.
  final DateTime time;

  /// The objects in the order of the Object_List, with the properties they
  /// returned (properties a device refused to read are left out).
  final Map<BacnetObject, Map<BacnetPropertyId, BacnetValue>> objects;

  /// The Device object.
  BacnetObject get device =>
      BacnetObject(type: BacnetObjectType.device, instance: deviceId);

  /// Object_Name of the device, if it was read.
  String? get deviceName =>
      objects[device]?[BacnetPropertyId.objectName]?.asString;

  /// Number of properties read.
  int get propertyCount =>
      objects.values.fold(0, (count, properties) => count + properties.length);

  /// The description as JSON (values as [BacnetValue.toJson]).
  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'time': time.toIso8601String(),
    'objects': [
      for (final MapEntry(key: object, value: properties) in objects.entries)
        {
          'type': object.type.value,
          'instance': object.instance,
          'properties': [
            for (final MapEntry(key: id, value: value) in properties.entries)
              {'id': id.value, 'name': id.label, 'value': value.toJson()},
          ],
        },
    ],
  };

  /// The objects in the notation of the object list of an EPICS (ASHRAE
  /// 135.1 Annex A): one block per object with `property-name: value`
  /// lines. Enumerations of the common properties are named, others are
  /// numbers.
  String toEpics() {
    final out = StringBuffer()
      ..writeln(
        '-- BACnet device $deviceId'
        '${deviceName == null ? '' : ' "${deviceName!}"'}, read $time',
      )
      ..writeln('List of Objects in Test Device:')
      ..writeln('{');
    var first = true;
    for (final MapEntry(key: object, value: properties) in objects.entries) {
      if (!first) out.writeln('  ,');
      first = false;
      out.writeln('  {');
      for (final MapEntry(key: id, value: value) in properties.entries) {
        out.writeln(
          '    ${epicsName(id.label)}: ${epicsValue(object, id, value)}',
        );
      }
      out.writeln('  }');
    }
    out.writeln('}');
    return out.toString();
  }

  @override
  bool operator ==(Object other) {
    if (other is! BacnetDeviceDescription ||
        other.deviceId != deviceId ||
        other.time != time ||
        other.objects.length != objects.length) {
      return false;
    }
    for (final MapEntry(key: object, value: properties) in objects.entries) {
      final theirs = other.objects[object];
      if (theirs == null || theirs.length != properties.length) return false;
      for (final MapEntry(key: id, value: value) in properties.entries) {
        if (theirs[id] != value) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(deviceId, time, objects.length);

  @override
  String toString() =>
      'BacnetDeviceDescription(device $deviceId, ${objects.length} objects, '
      '$propertyCount properties, $time)';
}
