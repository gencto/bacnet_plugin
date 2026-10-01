import '../constants/property_ids.dart';
import '../models/bacnet_value.dart';
import '../models/rpm_models.dart';

/// Throws an [ArgumentError] when [specs] request a property of an object
/// more than once: the results hold one entry per property and object.
void checkUniqueProperties(List<BacnetReadAccessSpecification> specs) {
  final seen = <(BacnetObject, BacnetPropertyId)>{};
  for (final spec in specs) {
    for (final property in spec.properties) {
      if (!seen.add((spec.objectIdentifier, property.propertyIdentifier))) {
        throw ArgumentError.value(
          specs,
          'specs',
          '${property.propertyIdentifier.label} of '
              '${spec.objectIdentifier} is requested more than once',
        );
      }
    }
  }
}
