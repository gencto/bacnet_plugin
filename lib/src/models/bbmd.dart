/// @docImport '../client/bbmd_client.dart';
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'construct_support.dart';

/// Result codes of a BVLC-Result message (BACnet/IP, Annex J.2.1): the
/// answer of a BBMD to requests that have no other answer, and its refusal
/// (NAK) of the others.
extension type const BacnetBvlcResult(int value) implements int {
  /// Successful completion.
  static const successfulCompletion = BacnetBvlcResult(0x0000);

  /// Write-Broadcast-Distribution-Table refused.
  static const writeBroadcastDistributionTableNak = BacnetBvlcResult(0x0010);

  /// Read-Broadcast-Distribution-Table refused (not a BBMD).
  static const readBroadcastDistributionTableNak = BacnetBvlcResult(0x0020);

  /// Register-Foreign-Device refused.
  static const registerForeignDeviceNak = BacnetBvlcResult(0x0030);

  /// Read-Foreign-Device-Table refused (not a BBMD).
  static const readForeignDeviceTableNak = BacnetBvlcResult(0x0040);

  /// Delete-Foreign-Device-Table-Entry refused (no such entry).
  static const deleteForeignDeviceTableEntryNak = BacnetBvlcResult(0x0050);

  /// Distribute-Broadcast-To-Network refused.
  static const distributeBroadcastToNetworkNak = BacnetBvlcResult(0x0060);

  static const Map<BacnetBvlcResult, String> _labels = {
    successfulCompletion: 'Successful Completion',
    writeBroadcastDistributionTableNak:
        'Write Broadcast Distribution Table NAK',
    readBroadcastDistributionTableNak: 'Read Broadcast Distribution Table NAK',
    registerForeignDeviceNak: 'Register Foreign Device NAK',
    readForeignDeviceTableNak: 'Read Foreign Device Table NAK',
    deleteForeignDeviceTableEntryNak: 'Delete Foreign Device Table Entry NAK',
    distributeBroadcastToNetworkNak: 'Distribute Broadcast To Network NAK',
  };

  /// All values defined by this library.
  static Iterable<BacnetBvlcResult> get values => _labels.keys;

  /// Human-readable name of [value].
  static String getName(int value) =>
      _labels[value] ??
      'BVLC Result 0x${value.toRadixString(16).padLeft(4, '0')}';

  /// Human-readable name.
  String get label => getName(value);
}

Uint8List _ipv4(String ipAddress, String name) {
  final octets = ipAddress.split('.').map(int.tryParse).toList();
  if (octets.length != 4 || octets.any((o) => o == null || o < 0 || o > 255)) {
    throw ArgumentError.value(ipAddress, name, 'not an IPv4 address');
  }
  return Uint8List.fromList(octets.cast<int>());
}

String _dotted(List<int> octets) => octets.join('.');

/// An entry of the Broadcast Distribution Table of a BBMD: a peer BBMD the
/// broadcasts of the local network are forwarded to.
@immutable
final class BacnetBdtEntry {
  /// Creates an entry for the BBMD at [ipAddress] and [port].
  ///
  /// [mask] is the broadcast distribution mask: 255.255.255.255 (the
  /// default) forwards broadcasts to the peer BBMD, which distributes them
  /// on its network ("two-hop"); the subnet mask of the peer's network sends
  /// them directly to its directed broadcast address ("one-hop").
  BacnetBdtEntry(
    String ipAddress, {
    this.port = 47808,
    String mask = '255.255.255.255',
  }) : address = _ipv4(ipAddress, 'ipAddress'),
       maskOctets = _ipv4(mask, 'mask') {
    RangeError.checkValueInInterval(port, 0, 0xFFFF, 'port');
  }

  BacnetBdtEntry._(this.address, this.port, this.maskOctets);

  /// Decodes the 10 octets of an entry at [offset] of [data].
  factory BacnetBdtEntry.decode(Uint8List data, int offset) => BacnetBdtEntry._(
    Uint8List.fromList(data.sublist(offset, offset + 4)),
    (data[offset + 4] << 8) | data[offset + 5],
    Uint8List.fromList(data.sublist(offset + 6, offset + 10)),
  );

  /// IPv4 address of the BBMD (4 octets).
  final Uint8List address;

  /// UDP port of the BBMD.
  final int port;

  /// Broadcast distribution mask (4 octets).
  final Uint8List maskOctets;

  /// IPv4 address of the BBMD.
  String get ipAddress => _dotted(address);

  /// Broadcast distribution mask.
  String get mask => _dotted(maskOctets);

  /// The 10 octets of the entry.
  List<int> encode() => [...address, port >> 8, port & 0xFF, ...maskOctets];

  @override
  bool operator ==(Object other) =>
      other is BacnetBdtEntry &&
      other.port == port &&
      listEquals(other.address, address) &&
      listEquals(other.maskOctets, maskOctets);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(address), port, Object.hashAll(maskOctets));

  @override
  String toString() => 'BacnetBdtEntry($ipAddress:$port, mask $mask)';
}

/// An entry of the Foreign Device Table of a BBMD: a device registered to
/// receive the broadcasts of the network (see
/// `BacnetClient.registerForeignDevice`).
@immutable
final class BacnetFdtEntry {
  /// Creates an entry.
  BacnetFdtEntry(
    String ipAddress, {
    required this.timeToLive,
    required this.remaining,
    this.port = 47808,
  }) : address = _ipv4(ipAddress, 'ipAddress') {
    RangeError.checkValueInInterval(port, 0, 0xFFFF, 'port');
    RangeError.checkValueInInterval(timeToLive, 0, 0xFFFF, 'timeToLive');
    RangeError.checkValueInInterval(remaining, 0, 0xFFFF, 'remaining');
  }

  BacnetFdtEntry._(this.address, this.port, this.timeToLive, this.remaining);

  /// Decodes the 10 octets of an entry at [offset] of [data].
  factory BacnetFdtEntry.decode(Uint8List data, int offset) => BacnetFdtEntry._(
    Uint8List.fromList(data.sublist(offset, offset + 4)),
    (data[offset + 4] << 8) | data[offset + 5],
    (data[offset + 6] << 8) | data[offset + 7],
    (data[offset + 8] << 8) | data[offset + 9],
  );

  /// IPv4 address of the foreign device (4 octets).
  final Uint8List address;

  /// UDP port of the foreign device.
  final int port;

  /// Time-to-live of the registration in seconds, as requested by the
  /// device.
  final int timeToLive;

  /// Seconds until the registration expires (including the grace period of
  /// 30 seconds the BBMD adds).
  final int remaining;

  /// IPv4 address of the foreign device.
  String get ipAddress => _dotted(address);

  /// The 10 octets of the entry.
  List<int> encode() => [
    ...address,
    port >> 8,
    port & 0xFF,
    timeToLive >> 8,
    timeToLive & 0xFF,
    remaining >> 8,
    remaining & 0xFF,
  ];

  @override
  bool operator ==(Object other) =>
      other is BacnetFdtEntry &&
      other.port == port &&
      other.timeToLive == timeToLive &&
      other.remaining == remaining &&
      listEquals(other.address, address);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(address), port, timeToLive, remaining);

  @override
  String toString() =>
      'BacnetFdtEntry($ipAddress:$port, ttl ${timeToLive}s, '
      '${remaining}s left)';
}
