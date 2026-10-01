import 'package:bacnet_plugin/bacnet_plugin.dart';

/// Formats a property value for display.
///
/// [BacnetValue] is sealed: the switch must handle every datatype, so a
/// new datatype is a compile error here instead of a wrong display.
String formatValue(BacnetValue value) => switch (value) {
  BacnetNull() => 'null',
  BacnetBoolean(:final value) => value ? 'true' : 'false',
  BacnetUnsigned(:final value) ||
  BacnetSigned(:final value) => value.toString(),
  BacnetReal(:final value) ||
  BacnetDouble(:final value) => value.toStringAsFixed(2),
  BacnetOctetString(:final value) => '${value.length} octets',
  BacnetCharacterString(:final value) => value,
  BacnetBitString(:final bits) => bits.map((b) => b ? '1' : '0').join(),
  BacnetEnumerated(:final value) => '#$value',
  BacnetDate(:final year, :final month, :final day) => '$year-$month-$day',
  BacnetTime(:final hour, :final minute, :final second) =>
    '$hour:$minute:$second',
  BacnetObject(:final type, :final instance) => '${type.label} $instance',
  BacnetList(:final items) => '[${items.map(formatValue).join(', ')}]',
  BacnetConstructedValue() || BacnetContextValue() => value.toString(),
};
