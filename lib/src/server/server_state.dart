import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../constants/object_types.dart';
import '../models/bacnet_value.dart';

/// The persisted state of one object a `BacnetServer` hosts: its identity, its
/// name and description, and its present value when it has one.
@immutable
final class BacnetObjectState {
  /// Creates the state of one object.
  const BacnetObjectState({
    required this.type,
    required this.instance,
    this.name,
    this.description,
    this.presentValue,
  });

  /// Reads a state stored with [toJson].
  factory BacnetObjectState.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    final instance = json['instance'];
    if (type is! int || instance is! int) {
      throw const FormatException('object state needs a type and instance');
    }
    final value = json['presentValue'];
    return BacnetObjectState(
      type: BacnetObjectType(type),
      instance: instance,
      name: json['name'] as String?,
      description: json['description'] as String?,
      presentValue: value is Map<String, Object?>
          ? BacnetValue.fromJson(value)
          : null,
    );
  }

  /// The object type.
  final BacnetObjectType type;

  /// The object instance.
  final int instance;

  /// The object name, if set.
  final String? name;

  /// The object description, if set.
  final String? description;

  /// The present value, for objects that have one.
  final BacnetValue? presentValue;

  /// Serializes the state as JSON.
  Map<String, Object?> toJson() => {
    'type': type.value,
    'instance': instance,
    if (name != null) 'name': name,
    if (description != null) 'description': description,
    if (presentValue != null) 'presentValue': presentValue!.toJson(),
  };

  @override
  String toString() => 'BacnetObjectState($type:$instance)';
}

/// A snapshot of the objects a `BacnetServer` hosts and their present values,
/// taken with `BacnetServer.captureState` and applied with
/// `BacnetServer.restoreState`.
@immutable
final class BacnetServerState {
  /// Creates a snapshot.
  const BacnetServerState({required this.objects, this.deviceInstance});

  /// Reads a snapshot stored with [toJson].
  factory BacnetServerState.fromJson(Map<String, Object?> json) {
    final objects = json['objects'];
    if (objects is! List) {
      throw const FormatException('server state needs an objects list');
    }
    return BacnetServerState(
      deviceInstance: json['deviceInstance'] as int?,
      objects: [
        for (final object in objects)
          if (object is Map<String, Object?>)
            BacnetObjectState.fromJson(object),
      ],
    );
  }

  /// The hosted objects.
  final List<BacnetObjectState> objects;

  /// The device instance at capture time, if known.
  final int? deviceInstance;

  /// Serializes the snapshot as JSON (stable, human-readable).
  Map<String, Object?> toJson() => {
    'version': 1,
    if (deviceInstance != null) 'deviceInstance': deviceInstance,
    'objects': [for (final object in objects) object.toJson()],
  };

  @override
  String toString() =>
      'BacnetServerState(${objects.length} objects'
      '${deviceInstance != null ? ', device $deviceInstance' : ''})';
}

/// A store that persists a [BacnetServerState] so a server can keep its
/// configuration across restarts (its container is ephemeral).
///
/// Implement it to persist to a database, an object store or any other
/// backend; [JsonFileServerStateStore] writes a JSON file.
///
/// ```dart
/// final store = JsonFileServerStateStore(File('/data/server.json'));
/// await server.restoreState(store); // on start, if a snapshot exists
/// // ... run; on changes or shutdown:
/// await server.saveState(store);
/// ```
abstract interface class BacnetServerStateStore {
  /// Persists [state], replacing any previously saved snapshot.
  Future<void> save(BacnetServerState state);

  /// Loads the saved snapshot, or null when none is stored.
  Future<BacnetServerState?> load();
}

/// A [BacnetServerStateStore] backed by a JSON file.
///
/// The file is written atomically (to a temporary file that replaces the
/// target) so a crash mid-write cannot corrupt a saved snapshot.
final class JsonFileServerStateStore implements BacnetServerStateStore {
  /// Stores the snapshot in [file].
  JsonFileServerStateStore(this.file);

  /// The JSON file.
  final File file;

  static const _encoder = JsonEncoder.withIndent('  ');

  @override
  Future<void> save(BacnetServerState state) async {
    final parent = file.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      _encoder.convert(state.toJson()),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  @override
  Future<BacnetServerState?> load() async {
    if (!file.existsSync()) {
      return null;
    }
    final text = await file.readAsString();
    if (text.trim().isEmpty) {
      return null;
    }
    final json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw const FormatException('server state file is not a JSON object');
    }
    return BacnetServerState.fromJson(json);
  }
}
