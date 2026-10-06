/// @docImport '../client/bacnet_client.dart';
/// @docImport '../core/exceptions.dart';
library;

import 'package:meta/meta.dart';

import '../constants/errors.dart';
import '../constants/property_ids.dart';
import 'bacnet_value.dart';
import 'construct_support.dart';

/// A property watched by [BacnetClient.subscribeCOVPropertyMultiple]
/// (BACnetCOVReference): [covIncrement] overrides the COV_Increment of
/// the object, [timestamped] asks for the time of each change.
@immutable
final class BacnetCovReference {
  /// Creates the reference.
  const BacnetCovReference(
    this.property, {
    this.arrayIndex,
    this.covIncrement,
    this.timestamped = false,
  });

  /// The property.
  final BacnetPropertyId property;

  /// Element of an array property, null for the whole property.
  final int? arrayIndex;

  /// Change of a numeric value that triggers a notification.
  final double? covIncrement;

  /// Whether notifications carry the time of each change.
  final bool timestamped;

  @override
  bool operator ==(Object other) =>
      other is BacnetCovReference &&
      other.property == property &&
      other.arrayIndex == arrayIndex &&
      other.covIncrement == covIncrement &&
      other.timestamped == timestamped;

  @override
  int get hashCode =>
      Object.hash(property, arrayIndex, covIncrement, timestamped);

  @override
  String toString() =>
      'BacnetCovReference(${property.label}'
      '${arrayIndex == null ? '' : '[$arrayIndex]'}'
      '${covIncrement == null ? '' : ', increment $covIncrement'}'
      '${timestamped ? ', timestamped' : ''})';
}

/// The properties of one object watched by
/// [BacnetClient.subscribeCOVPropertyMultiple]
/// (BACnetCOVSubscriptionSpecification).
@immutable
final class BacnetCovSubscriptionSpecification {
  /// Creates the specification.
  BacnetCovSubscriptionSpecification(
    this.object,
    List<BacnetCovReference> references,
  ) : references = List.unmodifiable(references) {
    if (references.isEmpty) {
      throw ArgumentError.value(references, 'references', 'is empty');
    }
  }

  /// The object.
  final BacnetObject object;

  /// Its properties.
  final List<BacnetCovReference> references;

  @override
  bool operator ==(Object other) =>
      other is BacnetCovSubscriptionSpecification &&
      other.object == object &&
      listEquals(other.references, references);

  @override
  int get hashCode => Object.hash(object, Object.hashAll(references));

  @override
  String toString() =>
      'BacnetCovSubscriptionSpecification($object, $references)';
}

/// The subscription a device refused in a SubscribeCOVPropertyMultiple
/// ([BacnetProtocolException.firstFailedSubscription]).
@immutable
final class BacnetFailedCovSubscription {
  /// Creates the description.
  const BacnetFailedCovSubscription({
    required this.object,
    required this.property,
    required this.errorClass,
    required this.errorCode,
    this.arrayIndex,
  });

  /// The object.
  final BacnetObject object;

  /// The property.
  final BacnetPropertyId property;

  /// Element of an array property, null for the whole property.
  final int? arrayIndex;

  /// Why the subscription failed.
  final BacnetErrorClass errorClass;

  /// Why the subscription failed.
  final BacnetErrorCode errorCode;

  @override
  bool operator ==(Object other) =>
      other is BacnetFailedCovSubscription &&
      other.object == object &&
      other.property == property &&
      other.arrayIndex == arrayIndex &&
      other.errorClass == errorClass &&
      other.errorCode == errorCode;

  @override
  int get hashCode =>
      Object.hash(object, property, arrayIndex, errorClass, errorCode);

  @override
  String toString() =>
      'BacnetFailedCovSubscription($object ${property.label}'
      '${arrayIndex == null ? '' : '[$arrayIndex]'}: '
      '${BacnetErrorClass.getName(errorClass)}: '
      '${BacnetErrorCode.getName(errorCode)})';
}
