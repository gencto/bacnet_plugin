// ignore_for_file: public_member_api_docs
// BVLC messages of BACnet/IP (ASHRAE 135 Annex J) that manage BBMDs.
// Internal: used by BacnetBbmdClient.

import 'dart:typed_data';

import '../core/exceptions.dart';
import '../models/bbmd.dart';

/// BVLC function codes (Annex J.2).
abstract final class BvlcFunction {
  static const int result = 0x00;
  static const int writeBroadcastDistributionTable = 0x01;
  static const int readBroadcastDistributionTable = 0x02;
  static const int readBroadcastDistributionTableAck = 0x03;
  static const int readForeignDeviceTable = 0x06;
  static const int readForeignDeviceTableAck = 0x07;
  static const int deleteForeignDeviceTableEntry = 0x08;
}

/// Size of the BVLC header (type, function, length).
const int bvlcHeaderSize = 4;

/// Size of an entry of the Broadcast Distribution and Foreign Device
/// Tables.
const int bvlcEntrySize = 10;

/// A BACnet/IP BVLL with [function] and [data].
Uint8List encodeBvlc(int function, [List<int> data = const []]) {
  final length = bvlcHeaderSize + data.length;
  if (length > 0xFFFF) {
    throw BacnetEncodeException('BVLL of $length octets is too long');
  }
  return Uint8List.fromList([
    0x81,
    function,
    length >> 8,
    length & 0xFF,
    ...data,
  ]);
}

/// The function and data of a BACnet/IP BVLL. Throws a
/// [BacnetDecodeException] if [packet] is not one.
({int function, Uint8List data}) decodeBvlc(Uint8List packet) {
  if (packet.length < bvlcHeaderSize || packet[0] != 0x81) {
    throw const BacnetDecodeException('not a BACnet/IP BVLL');
  }
  final length = (packet[2] << 8) | packet[3];
  if (length != packet.length) {
    throw BacnetDecodeException(
      'BVLL length $length does not match ${packet.length} octets',
    );
  }
  return (
    function: packet[1],
    data: Uint8List.sublistView(packet, bvlcHeaderSize),
  );
}

/// The entries of a Write-Broadcast-Distribution-Table or
/// Read-Broadcast-Distribution-Table-Ack.
Uint8List encodeBroadcastDistributionTable(List<BacnetBdtEntry> entries) =>
    Uint8List.fromList([for (final entry in entries) ...entry.encode()]);

/// Decodes the entries of a Read-Broadcast-Distribution-Table-Ack.
List<BacnetBdtEntry> decodeBroadcastDistributionTable(Uint8List data) {
  _checkEntries(data, 'Broadcast Distribution Table');
  return List.unmodifiable([
    for (var offset = 0; offset < data.length; offset += bvlcEntrySize)
      BacnetBdtEntry.decode(data, offset),
  ]);
}

/// Decodes the entries of a Read-Foreign-Device-Table-Ack.
List<BacnetFdtEntry> decodeForeignDeviceTable(Uint8List data) {
  _checkEntries(data, 'Foreign Device Table');
  return List.unmodifiable([
    for (var offset = 0; offset < data.length; offset += bvlcEntrySize)
      BacnetFdtEntry.decode(data, offset),
  ]);
}

/// The result code of a BVLC-Result.
BacnetBvlcResult decodeBvlcResult(Uint8List data) {
  if (data.length != 2) {
    throw BacnetDecodeException('BVLC-Result of ${data.length} octets');
  }
  return BacnetBvlcResult((data[0] << 8) | data[1]);
}

void _checkEntries(Uint8List data, String table) {
  if (data.length % bvlcEntrySize != 0) {
    throw BacnetDecodeException(
      '$table of ${data.length} octets is not a list of entries',
    );
  }
}
