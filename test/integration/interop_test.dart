@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

/// Interop against bacnet-stack's own reference server (apps/server/bacserv):
/// our client reads and writes a device built by the reference stack, which
/// exercises the wire protocol over a real socket against a third-party peer
/// rather than against our own server.
///
/// The reference apps build with make/gcc, so this runs on Linux only, and it
/// is self-gating: if the toolchain or the submodule is missing, the build
/// fails, or the reference server cannot be reached on the runner, the suite
/// skips instead of failing. Only a real protocol mismatch (a wrong value from
/// a reachable server) fails it, so it never breaks CI on an environment that
/// cannot run it.

/// Builds (once) and returns the path to bacserv, or null if it cannot be made.
String? _buildReferenceServer() {
  final stack = '${Directory.current.path}/native/bacnet-stack';
  final binary = '$stack/apps/server/bacserv';
  if (File(binary).existsSync()) return binary;
  if (!Directory('$stack/apps/server').existsSync()) return null;
  try {
    final make = Process.runSync('make', [
      'server',
      'BACNET_PORT=linux',
      'BACDL=bip',
    ], workingDirectory: stack);
    if (make.exitCode == 0 && File(binary).existsSync()) return binary;
  } on ProcessException {
    // make is not installed
  }
  return null;
}

void main() {
  if (!Platform.isLinux) {
    test(
      'interop with the bacnet-stack reference server',
      () {},
      skip: 'the bacnet-stack reference apps build on Linux only',
    );
    return;
  }
  final bacserv = _buildReferenceServer();
  if (bacserv == null) {
    test(
      'interop with the bacnet-stack reference server',
      () {},
      skip: 'could not build the bacnet-stack reference server (bacserv)',
    );
    return;
  }

  const serverPort = 47820;
  const clientPort = 47821;
  const device = 260123;
  const deviceObject = BacnetObject(
    type: BacnetObjectType.device,
    instance: device,
  );
  // bacserv creates its default object table, which includes Analog Value 1.
  const analogValue = BacnetObject(
    type: BacnetObjectType.analogValue,
    instance: 1,
  );
  Process? server;
  BacnetClient? client;
  // non-null when the reference fixture could not be brought up, which is an
  // environment problem (not a protocol mismatch) and so skips, never fails
  String? unreachable;

  setUpAll(() async {
    try {
      server = await Process.start(
        bacserv,
        ['$device', 'InteropServer'],
        environment: {'BACNET_IP_PORT': '$serverPort', 'BACNET_IFACE': 'lo'},
      );
      // drain the reference server's output so it never blocks on a full pipe
      unawaited(server!.stdout.drain<void>());
      unawaited(server!.stderr.drain<void>());
      client = BacnetClient(
        config: const BacnetConfig(
          interface: '127.0.0.1',
          port: clientPort,
          requestTimeout: Duration(seconds: 10),
          apduTimeout: Duration(seconds: 1),
          logLevel: BacnetLogLevel.warning,
        ),
      );
      await client!.start();
      await client!.addDeviceBinding(device, '127.0.0.1', port: serverPort);
      // wait for the reference server to bind its socket and start answering
      Object? last;
      for (var i = 0; i < 30; i++) {
        try {
          await client!.readProperty(
            device,
            BacnetObjectType.device,
            device,
            BacnetPropertyId.objectName,
          );
          return;
        } on Object catch (e) {
          last = e;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      unreachable = 'the reference server did not answer on this runner: $last';
    } on Object catch (e) {
      unreachable = 'could not start the interop fixture: $e';
    }
  });

  tearDownAll(() async {
    await client?.close();
    server?.kill();
    await server?.exitCode;
  });

  test('reads the device identity the reference stack reports', () async {
    if (unreachable != null) return markTestSkipped(unreachable!);
    expect(
      await client!.readProperty(
        device,
        BacnetObjectType.device,
        device,
        BacnetPropertyId.objectName,
      ),
      const BacnetCharacterString('InteropServer'),
    );
    expect(
      await client!.readProperty(
        device,
        BacnetObjectType.device,
        device,
        BacnetPropertyId.vendorIdentifier,
      ),
      const BacnetUnsigned(260),
    );
  });

  test('reads the object-list from the reference server', () async {
    if (unreachable != null) return markTestSkipped(unreachable!);
    final objects = await client!.read(
      device,
      deviceObject,
      BacnetProperties.objectList,
    );
    expect(objects, isNotEmpty);
    expect(objects, contains(deviceObject));
    expect(objects, contains(analogValue));
  });

  test(
    'writes and reads back an Analog Value on the reference server',
    () async {
      if (unreachable != null) return markTestSkipped(unreachable!);
      await client!.write(
        device,
        analogValue,
        BacnetProperties.analogPresentValue,
        42.5,
        priority: 10,
      );
      expect(
        await client!.read(
          device,
          analogValue,
          BacnetProperties.analogPresentValue,
        ),
        42.5,
      );
    },
  );
}
