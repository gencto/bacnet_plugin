// BACnet/IP addresses of hosts (internal, not exported).

import 'dart:io';
import 'dart:typed_data';

/// The BACnet/IP address of [host] (an IPv4 address or a host name) and
/// [port]: 4 bytes IPv4 address and 2 bytes port.
Future<Uint8List> resolveBacnetIp(String host, int port) async {
  RangeError.checkValueInInterval(port, 0, 0xFFFF, 'port');
  var address = InternetAddress.tryParse(host);
  if (address == null) {
    final found = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    );
    if (found.isEmpty) {
      throw ArgumentError.value(host, 'host', 'no IPv4 address');
    }
    address = found.first;
  }
  if (address.type != InternetAddressType.IPv4) {
    throw ArgumentError.value(host, 'host', 'not an IPv4 address');
  }
  return Uint8List.fromList([...address.rawAddress, port >> 8, port & 0xFF]);
}
