@Tags(['integration'])
library;

import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

/// Whether this host has a usable IPv6 loopback; the BACnet/IPv6 datalink
/// cannot open a socket without it (e.g. containers with IPv6 disabled), so
/// the test skips there rather than failing.
Future<bool> _ipv6Available() async {
  try {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv6,
      0,
    );
    socket.close();
    return true;
  } on Object {
    return false;
  }
}

Future<void> main() async {
  final ipv6 = await _ipv6Available();
  test('starts a server on the BACnet/IPv6 datalink', () async {
    final server = BacnetServer(
      config: const BacnetConfig(
        interface: 'lo',
        port: 47810,
        useIPv6: true,
        logLevel: BacnetLogLevel.warning,
      ),
    );
    await server.start();
    try {
      // 4194302 is the maximum assignable device instance (4194303 is the
      // reserved "unconfigured" value)
      await server.init(4194302, 'IPv6Server');
      await server.addObject(
        BacnetObjectType.analogValue,
        1,
        name: 'v6',
        presentValue: const BacnetReal(1),
      );
      // the server reads its own object over the IPv6 stack
      expect(
        await server.read(
          const BacnetObject(type: BacnetObjectType.analogValue, instance: 1),
          BacnetProperties.objectName,
        ),
        'v6',
      );
    } finally {
      await server.close();
    }
  }, skip: ipv6 ? false : 'no IPv6 loopback on this host');
}
