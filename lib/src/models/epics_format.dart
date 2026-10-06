// The notation of EPICS (ASHRAE 135.1 Annex A) for property values, used
// by BacnetDeviceDescription.toEpics and the command line tool.

import '../constants/engineering_units.dart';
import '../constants/enumerations.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import 'bacnet_value.dart';

/// The EPICS name of a label: `Analog Input` → `analog-input`.
String epicsName(String label) => label
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-|-$'), '');

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];
const _weekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', //
  'Sunday',
];

/// [value] of [property] of [object] in the notation of an EPICS (ASHRAE
/// 135.1 Annex A).
String epicsValue(
  BacnetObject object,
  BacnetPropertyId property,
  BacnetValue value,
) => switch (value) {
  BacnetNull() => 'NULL',
  BacnetBoolean(:final value) => value ? 'TRUE' : 'FALSE',
  BacnetUnsigned(:final value) || BacnetSigned(:final value) => '$value',
  BacnetReal(:final value) || BacnetDouble(:final value) => '$value',
  BacnetCharacterString(:final value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"',
  BacnetOctetString(:final value) =>
    "X'${value.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'",
  BacnetBitString(:final bits) =>
    '{${bits.map((b) => b ? 'T' : 'F').join(',')}}',
  BacnetEnumerated(:final value) => _epicsEnumerated(object, property, value),
  BacnetDate(:final year, :final month, :final day, :final weekday) =>
    '(${weekday == null || weekday < 1 || weekday > 7 ? '*' : _weekdays[weekday - 1]}, '
        '${day ?? '*'}-'
        '${month == null || month < 1 || month > 12 ? '*' : _months[month - 1]}-'
        '${year ?? '*'})',
  BacnetTime(:final hour, :final minute, :final second, :final hundredths) =>
    '${_two(hour)}:${_two(minute)}:${_two(second)}.${_two(hundredths)}',
  BacnetObject(:final type, :final instance) =>
    '(${_objectType(type)}, $instance)',
  BacnetList(:final items) =>
    '{${items.map((item) => epicsValue(object, property, item)).join(', ')}}',
  BacnetConstructedValue(:final values) =>
    '{${values.map((item) => epicsValue(object, property, item)).join(', ')}}',
  BacnetContextValue(:final tag, :final data) =>
    "[$tag]X'${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'",
};

String _two(int? value) => value == null ? '*' : '$value'.padLeft(2, '0');

String _objectType(BacnetObjectType type) {
  final label = BacnetObjectType.getName(type);
  return label.startsWith('Unknown') ? 'proprietary-$type' : epicsName(label);
}

/// Names the enumerations of the common properties.
String _epicsEnumerated(
  BacnetObject object,
  BacnetPropertyId property,
  int value,
) {
  final label = switch (property) {
    BacnetPropertyId.objectType => BacnetObjectType.getName(value),
    BacnetPropertyId.units => BacnetEngineeringUnits.getName(value),
    BacnetPropertyId.eventState => BacnetEventState.getName(value),
    BacnetPropertyId.reliability => BacnetReliability.getName(value),
    BacnetPropertyId.notifyType => BacnetNotifyType.getName(value),
    BacnetPropertyId.systemStatus => BacnetDeviceStatus.getName(value),
    BacnetPropertyId.segmentationSupported => const [
      'Segmented Both',
      'Segmented Transmit',
      'Segmented Receive',
      'No Segmentation',
    ].elementAtOrNull(value),
    BacnetPropertyId.polarity => BacnetPolarity.getName(value),
    BacnetPropertyId.presentValue ||
    BacnetPropertyId.relinquishDefault ||
    BacnetPropertyId.alarmValue ||
    BacnetPropertyId.feedbackValue when _binaryTypes.contains(object.type) =>
      BacnetBinaryPV.getName(value),
    _ => null,
  };
  return label == null ? '$value' : epicsName(label);
}

const _binaryTypes = {
  BacnetObjectType.binaryInput,
  BacnetObjectType.binaryOutput,
  BacnetObjectType.binaryValue,
};
