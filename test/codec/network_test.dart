import 'dart:math';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

import '../support/alarm_vectors.dart';

// Messages encoded by bacnet-stack (Send_Network_Layer_Message of
// basic/npdu/s_router.c): message type and the octets after it.
final _vectors = <(BacnetNetworkMessageType, String, BacnetNetworkMessage)>[
  (
    BacnetNetworkMessageType.whoIsRouterToNetwork,
    '',
    BacnetWhoIsRouterToNetwork(),
  ),
  (
    BacnetNetworkMessageType.whoIsRouterToNetwork,
    '04d2',
    BacnetWhoIsRouterToNetwork(network: 1234),
  ),
  (
    BacnetNetworkMessageType.iAmRouterToNetwork,
    '00010002fffe',
    BacnetIAmRouterToNetwork([1, 2, 0xFFFE]),
  ),
  (
    BacnetNetworkMessageType.routerBusyToNetwork,
    '00010002fffe',
    BacnetRouterBusyToNetwork([1, 2, 0xFFFE]),
  ),
  (
    BacnetNetworkMessageType.routerAvailableToNetwork,
    '',
    BacnetRouterAvailableToNetwork([]),
  ),
  (
    BacnetNetworkMessageType.rejectMessageToNetwork,
    '0110e1',
    BacnetRejectMessageToNetwork(
      reason: BacnetNetworkRejectReason.noRoute,
      network: 4321,
    ),
  ),
  (
    BacnetNetworkMessageType.initializeRoutingTable,
    '00',
    BacnetInitializeRoutingTable(),
  ),
  (
    BacnetNetworkMessageType.initializeRoutingTableAck,
    '030001010000020200fffe0300',
    BacnetInitializeRoutingTableAck([
      BacnetRoutingTableEntry(network: 1, portId: 1),
      BacnetRoutingTableEntry(network: 2, portId: 2),
      BacnetRoutingTableEntry(network: 0xFFFE, portId: 3),
    ]),
  ),
  (
    BacnetNetworkMessageType.networkNumberIs,
    '000701',
    BacnetNetworkNumberIs(network: 7, configured: true),
  ),
];

void main() {
  group('network messages', () {
    for (final (type, hex, message) in _vectors) {
      test('${type.label} $hex matches bacnet-stack', () {
        expect(BacnetNetworkMessage.decode(type, hexBytes(hex)), message);
        expect(message.encode(), hexBytes(hex));
        expect(message.type, type);
      });
    }

    test('routing table entries carry port info', () {
      final ack = BacnetInitializeRoutingTableAck([
        BacnetRoutingTableEntry(network: 5, portId: 1, portInfo: [1, 2, 3]),
        BacnetRoutingTableEntry(network: 6, portId: 0),
      ]);
      final encoded = ack.encode();
      expect(encoded, hexBytes('020005010301020300060000'));
      expect(
        BacnetNetworkMessage.decode(
          BacnetNetworkMessageType.initializeRoutingTableAck,
          encoded,
        ),
        ack,
      );
    });

    test('learned network numbers and What-Is-Network-Number', () {
      expect(
        BacnetNetworkMessage.decode(
          BacnetNetworkMessageType.networkNumberIs,
          hexBytes('000700'),
        ),
        BacnetNetworkNumberIs(network: 7),
      );
      expect(
        BacnetNetworkMessage.decode(
          BacnetNetworkMessageType.whatIsNetworkNumber,
          const [],
        ),
        const BacnetWhatIsNetworkNumber(),
      );
      expect(const BacnetWhatIsNetworkNumber().encode(), isEmpty);
    });

    test('I-Could-Be-Router-To-Network', () {
      final message = BacnetICouldBeRouterToNetwork(
        network: 9,
        performanceIndex: 20,
      );
      expect(message.encode(), hexBytes('000914'));
      expect(
        BacnetNetworkMessage.decode(
          BacnetNetworkMessageType.iCouldBeRouterToNetwork,
          message.encode(),
        ),
        message,
      );
    });

    test('other messages keep their octets and vendor', () {
      final message = BacnetNetworkMessage.decode(
        const BacnetNetworkMessageType(0x80),
        const [1, 2, 3],
        vendorId: 260,
      );
      expect(
        message,
        BacnetOtherNetworkMessage(const BacnetNetworkMessageType(0x80), const [
          1,
          2,
          3,
        ], vendorId: 260),
      );
      expect(message.vendorId, 260);
      expect(message.encode(), [1, 2, 3]);
      expect(
        BacnetNetworkMessage.decode(
          BacnetNetworkMessageType.securityPayload,
          const [9],
        ),
        isA<BacnetOtherNetworkMessage>(),
      );
    });

    test('malformed messages raise BacnetDecodeException', () {
      for (final (type, hex) in [
        (BacnetNetworkMessageType.whoIsRouterToNetwork, '04'),
        (BacnetNetworkMessageType.whoIsRouterToNetwork, '0000'),
        (BacnetNetworkMessageType.iAmRouterToNetwork, '000100'),
        (BacnetNetworkMessageType.iAmRouterToNetwork, 'ffff'),
        (BacnetNetworkMessageType.iCouldBeRouterToNetwork, '0009'),
        (BacnetNetworkMessageType.rejectMessageToNetwork, '0110'),
        (BacnetNetworkMessageType.routerBusyToNetwork, '0000'),
        (BacnetNetworkMessageType.initializeRoutingTable, ''),
        (BacnetNetworkMessageType.initializeRoutingTableAck, '01000101'),
        (BacnetNetworkMessageType.initializeRoutingTableAck, '0100050102aa'),
        (BacnetNetworkMessageType.initializeRoutingTableAck, '0100000100'),
        (BacnetNetworkMessageType.networkNumberIs, '0007'),
        (BacnetNetworkMessageType.networkNumberIs, '000001'),
      ]) {
        expect(
          () => BacnetNetworkMessage.decode(type, hexBytes(hex)),
          throwsA(isA<BacnetDecodeException>()),
          reason: '${type.label} $hex',
        );
      }
    });

    test('random messages only raise BacnetDecodeException', () {
      final random = Random(42);
      for (var i = 0; i < 20000; i++) {
        final type = BacnetNetworkMessageType(random.nextInt(21));
        final data = List.generate(
          random.nextInt(24),
          (_) => random.nextInt(256),
        );
        try {
          final message = BacnetNetworkMessage.decode(type, data);
          // what decodes encodes to the same octets (trailing data aside)
          final encoded = message.encode();
          expect(
            BacnetNetworkMessage.decode(type, encoded),
            message,
            reason: '${type.label} $data',
          );
        } on BacnetDecodeException {
          // expected for malformed input
        }
      }
    });

    test('constructors check network numbers', () {
      expect(() => BacnetWhoIsRouterToNetwork(network: 0), throwsArgumentError);
      expect(() => BacnetIAmRouterToNetwork([0xFFFF]), throwsArgumentError);
      expect(
        () => BacnetNetworkNumberIs(network: 0x10000),
        throwsArgumentError,
      );
      expect(
        () => BacnetRoutingTableEntry(network: 1, portId: 256),
        throwsArgumentError,
      );
    });

    test('events and routers describe their source', () {
      final event = NetworkMessageEvent(
        message: BacnetIAmRouterToNetwork([5]),
        mac: const [192, 168, 1, 1, 0xBA, 0xC0],
      );
      expect(event.ipAddress, '192.168.1.1');
      expect(event.port, 47808);
      expect(event.toString(), contains('192.168.1.1:47808'));
      final router = BacnetRouter(
        mac: const [10, 0, 0, 1, 0xBA, 0xC1],
        networks: const [5, 6],
      );
      expect(router.ipAddress, '10.0.0.1');
      expect(router.port, 47809);
      expect(router.toString(), 'BacnetRouter(10.0.0.1:47809, networks 5, 6)');
    });
  });
}
