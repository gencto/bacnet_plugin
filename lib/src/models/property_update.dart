import 'package:meta/meta.dart';

import 'bacnet_object.dart';

/// Source of the property update.
enum UpdateSource {
  /// Received via Change Of Value notification.
  cov,

  /// Received via active polling (ReadProperty).
  missingCovFallback,

  /// Manually read or other source.
  manual,
}

/// Represents a property value update.
@immutable
class PropertyUpdate {
  /// Creates a property update.
  const PropertyUpdate({
    required this.deviceId,
    required this.objectIdentifier,
    required this.propertyIdentifier,
    required this.value,
    required this.timestamp,
    required this.source,
    this.error,
  });

  /// Device ID that originated the update.
  final int deviceId;

  /// Object identifier of the property.
  final BacnetObject objectIdentifier;

  /// Property identifier.
  final int propertyIdentifier;

  /// New property value.
  final dynamic value;

  /// Time of the update.
  final DateTime timestamp;

  /// Source of the update.
  final UpdateSource source;

  /// Error object if the update represents a failure.
  final Object? error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PropertyUpdate &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId &&
          objectIdentifier == other.objectIdentifier &&
          propertyIdentifier == other.propertyIdentifier &&
          value == other.value &&
          timestamp == other.timestamp &&
          source == other.source &&
          error == other.error;

  @override
  int get hashCode =>
      deviceId.hashCode ^
      objectIdentifier.hashCode ^
      propertyIdentifier.hashCode ^
      value.hashCode ^
      timestamp.hashCode ^
      source.hashCode ^
      error.hashCode;

  @override
  String toString() {
    return 'PropertyUpdate{deviceId: $deviceId, object: $objectIdentifier, '
        'property: $propertyIdentifier, value: $value, source: $source}';
  }
}
