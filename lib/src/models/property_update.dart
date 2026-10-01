/// @docImport '../utilities/property_monitor.dart';
library;

import 'package:meta/meta.dart';

import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import 'bacnet_value.dart';

/// Source of the property update.
enum UpdateSource {
  /// Received via Change Of Value notification.
  cov,

  /// Received via active polling (ReadProperty).
  missingCovFallback,

  /// Manually read or other source.
  manual,
}

/// An update of a monitored property, emitted by [PropertyMonitor]: a new
/// [PropertyValueUpdate] or a [PropertyErrorUpdate] when reading failed.
///
/// The class is sealed, so the value is only reachable once the update is
/// known to carry one:
///
/// ```dart
/// monitor.monitorPresentValue(1234, sensor).listen((update) {
///   switch (update) {
///     case PropertyValueUpdate(:final value):
///       print('now ${value.asDouble}');
///     case PropertyErrorUpdate(:final error):
///       print('read failed: $error');
///   }
/// });
/// ```
@immutable
sealed class PropertyUpdate {
  const PropertyUpdate({
    required this.deviceId,
    required this.objectIdentifier,
    required this.propertyIdentifier,
    required this.timestamp,
    required this.source,
  });

  /// Device that hosts the property.
  final int deviceId;

  /// Object of the property.
  final BacnetObject objectIdentifier;

  /// Property identifier.
  final BacnetPropertyId propertyIdentifier;

  /// Time of the update.
  final DateTime timestamp;

  /// Source of the update.
  final UpdateSource source;
}

/// A new value of a monitored property.
final class PropertyValueUpdate extends PropertyUpdate {
  /// Creates a value update.
  const PropertyValueUpdate({
    required super.deviceId,
    required super.objectIdentifier,
    required super.propertyIdentifier,
    required this.value,
    required super.timestamp,
    required super.source,
  });

  /// The new value.
  final BacnetValue value;

  @override
  bool operator ==(Object other) =>
      other is PropertyValueUpdate &&
      other.deviceId == deviceId &&
      other.objectIdentifier == objectIdentifier &&
      other.propertyIdentifier == propertyIdentifier &&
      other.value == value &&
      other.timestamp == timestamp &&
      other.source == source;

  @override
  int get hashCode => Object.hash(
    deviceId,
    objectIdentifier,
    propertyIdentifier,
    value,
    timestamp,
    source,
  );

  @override
  String toString() =>
      'PropertyValueUpdate(device: $deviceId, object: $objectIdentifier, '
      'property: ${propertyIdentifier.label}, value: $value, '
      'source: ${source.name})';
}

/// Reading a monitored property failed.
final class PropertyErrorUpdate extends PropertyUpdate {
  /// Creates an error update.
  const PropertyErrorUpdate({
    required super.deviceId,
    required super.objectIdentifier,
    required super.propertyIdentifier,
    required this.error,
    required super.timestamp,
    required super.source,
  });

  /// Why the read failed.
  final BacnetException error;

  @override
  bool operator ==(Object other) =>
      other is PropertyErrorUpdate &&
      other.deviceId == deviceId &&
      other.objectIdentifier == objectIdentifier &&
      other.propertyIdentifier == propertyIdentifier &&
      other.error == error &&
      other.timestamp == timestamp &&
      other.source == source;

  @override
  int get hashCode => Object.hash(
    deviceId,
    objectIdentifier,
    propertyIdentifier,
    error,
    timestamp,
    source,
  );

  @override
  String toString() =>
      'PropertyErrorUpdate(device: $deviceId, object: $objectIdentifier, '
      'property: ${propertyIdentifier.label}, error: $error, '
      'source: ${source.name})';
}
