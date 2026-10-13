@Tags(['integration'])
library;

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

/// Server-only (no client): one BacnetSystem per process. Verifies the Network
/// Port object the server configures from its datalink (ASHRAE 135 clause
/// 12.56), read back through the server's own local read.
void main() {
  const deviceId = 9100;
  const port = 47898;
  late BacnetServer server;

  setUp(() async {
    server = BacnetServer(
      config: const BacnetConfig(
        // the loopback IP, not the interface name: macOS names it lo0, not lo
        interface: '127.0.0.1',
        port: port,
        logLevel: BacnetLogLevel.warning,
      ),
    );
    await server.start();
    await server.init(deviceId, 'NetPortTest');
  });

  tearDown(() async {
    await server.close();
  });

  Future<BacnetValue> read(BacnetPropertyId property) =>
      server.readProperty(BacnetObjectType.networkPort, 1, property);

  test('configures a Network Port object from the datalink', () async {
    expect(
      (await read(BacnetPropertyId.objectName)).asString,
      'BACnet/IP Port',
    );
    // PORT_TYPE_BIP
    expect((await read(BacnetPropertyId.networkType)).asInt, 5);
    expect((await read(BacnetPropertyId.bacnetIpUdpPort)).asInt, port);
    expect((await read(BacnetPropertyId.apduLength)).asInt, 1476);
    expect((await read(BacnetPropertyId.networkNumber)).asInt, 0);
  });

  test('exposes the Network Port in the device object list', () async {
    final list = (await server.readProperty(
      BacnetObjectType.device,
      deviceId,
      BacnetPropertyId.objectList,
    )).asList;
    expect(
      list,
      contains(
        const BacnetObject(type: BacnetObjectType.networkPort, instance: 1),
      ),
    );
    // the unconfigured instance-0 placeholder is gone
    expect(
      list,
      isNot(
        contains(
          const BacnetObject(type: BacnetObjectType.networkPort, instance: 0),
        ),
      ),
    );
  });

  test('configureNetworkPort overrides the name and network number', () async {
    await server.configureNetworkPort(networkNumber: 42, name: 'Primary Port');
    expect((await read(BacnetPropertyId.objectName)).asString, 'Primary Port');
    expect((await read(BacnetPropertyId.networkNumber)).asInt, 42);
  });

  test('advertises transmit segmentation consistently', () async {
    final seg = await server.readProperty(
      BacnetObjectType.device,
      deviceId,
      BacnetPropertyId.segmentationSupported,
    );
    // SEGMENTATION_TRANSMIT: sends segmented responses, no segmented requests
    expect(seg.asInt, 1);
    final maxSegs = await server.readProperty(
      BacnetObjectType.device,
      deviceId,
      BacnetPropertyId.maxSegmentsAccepted,
    );
    // accepts a one-segment (unsegmented) request only, matching the above
    expect(maxSegs.asInt, 1);
  });
}
