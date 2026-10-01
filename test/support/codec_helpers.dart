import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';

/// Shorthand for a byte list.
Uint8List bytes(List<int> values) => Uint8List.fromList(values);

/// Hex dump used in expectations (`0c 00 00 00 05`).
String hex(Uint8List data) =>
    data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// Encodes [value] as application data and decodes it again.
Object? roundTrip(Object? value, {int? tag}) {
  final writer = BacnetWriter();
  encodeApplicationValue(writer, value, tag: tag);
  return BacnetReader(writer.toBytes()).readApplicationValue();
}
