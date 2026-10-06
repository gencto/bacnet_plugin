import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/bvlc.dart';
import 'package:test/test.dart';

import '../support/alarm_vectors.dart';
import '../support/udp.dart';

// BVLLs encoded by bacnet-stack (bvlc_encode_* of datalink/bvlc.c)
const _readBdt = '81020004';
const _readBdtAck = '81030018c0a8010abac0ffffffff0a000001bac1ffffff00';
const _writeBdt = '81010018c0a8010abac0ffffffff0a000001bac1ffffff00';
const _readFdt = '81060004';
const _readFdtAck = '81070018c0a8010abac0003c005a0a000001bac1012c007b';
const _deleteFdtEntry = '8108000a0a000001bac1';
const _resultOk = '810000060000';
const _resultReadBdtNak = '810000060020';
const _readBdtAckEmpty = '81030004';

final _bdt = [
  BacnetBdtEntry('192.168.1.10'),
  BacnetBdtEntry('10.0.0.1', port: 47809, mask: '255.255.255.0'),
];

final _fdt = [
  BacnetFdtEntry('192.168.1.10', timeToLive: 60, remaining: 90),
  BacnetFdtEntry('10.0.0.1', port: 47809, timeToLive: 300, remaining: 123),
];

/// Answers BVLC requests on an ephemeral loopback port with [answer].
final class _FakeBbmd {
  _FakeBbmd._(this._socket, this.answer) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket.receive();
      if (datagram == null) return;
      requests.add(datagram.data);
      for (final reply in answer(datagram.data, datagram.port)) {
        sendDatagram(_socket, reply, datagram.address, datagram.port);
      }
    });
  }

  static Future<_FakeBbmd> bind(
    List<Uint8List> Function(Uint8List request, int clientPort) answer,
  ) async => _FakeBbmd._(
    await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
    answer,
  );

  final RawDatagramSocket _socket;
  final List<Uint8List> Function(Uint8List request, int clientPort) answer;
  final List<Uint8List> requests = [];

  int get port => _socket.port;

  void close() => _socket.close();
}

void main() {
  group('BVLC codec', () {
    test('requests match bacnet-stack', () {
      expect(
        encodeBvlc(BvlcFunction.readBroadcastDistributionTable),
        hexBytes(_readBdt),
      );
      expect(
        encodeBvlc(BvlcFunction.readForeignDeviceTable),
        hexBytes(_readFdt),
      );
      expect(
        encodeBvlc(
          BvlcFunction.writeBroadcastDistributionTable,
          encodeBroadcastDistributionTable(_bdt),
        ),
        hexBytes(_writeBdt),
      );
      expect(
        encodeBvlc(BvlcFunction.deleteForeignDeviceTableEntry, [
          10, 0, 0, 1, 0xBA, 0xC1, //
        ]),
        hexBytes(_deleteFdtEntry),
      );
    });

    test('answers of bacnet-stack decode', () {
      final bdt = decodeBvlc(hexBytes(_readBdtAck));
      expect(bdt.function, BvlcFunction.readBroadcastDistributionTableAck);
      expect(decodeBroadcastDistributionTable(bdt.data), _bdt);
      expect(
        decodeBroadcastDistributionTable(
          decodeBvlc(hexBytes(_readBdtAckEmpty)).data,
        ),
        isEmpty,
      );
      final fdt = decodeBvlc(hexBytes(_readFdtAck));
      expect(fdt.function, BvlcFunction.readForeignDeviceTableAck);
      expect(decodeForeignDeviceTable(fdt.data), _fdt);
      expect(
        decodeBvlcResult(decodeBvlc(hexBytes(_resultOk)).data),
        BacnetBvlcResult.successfulCompletion,
      );
      expect(
        decodeBvlcResult(decodeBvlc(hexBytes(_resultReadBdtNak)).data),
        BacnetBvlcResult.readBroadcastDistributionTableNak,
      );
    });

    test('malformed BVLLs raise BacnetDecodeException', () {
      for (final hex in ['8103', '82030004', '81030005', '8103000600']) {
        expect(
          () => decodeBvlc(hexBytes(hex)),
          throwsA(isA<BacnetDecodeException>()),
          reason: hex,
        );
      }
      expect(
        () => decodeBroadcastDistributionTable(Uint8List(9)),
        throwsA(isA<BacnetDecodeException>()),
      );
      expect(
        () => decodeForeignDeviceTable(Uint8List(11)),
        throwsA(isA<BacnetDecodeException>()),
      );
      expect(
        () => decodeBvlcResult(Uint8List(3)),
        throwsA(isA<BacnetDecodeException>()),
      );
    });

    test('entries describe themselves', () {
      expect(_bdt[1].ipAddress, '10.0.0.1');
      expect(_bdt[1].mask, '255.255.255.0');
      expect(
        _bdt[1].toString(),
        'BacnetBdtEntry(10.0.0.1:47809, mask 255.255.255.0)',
      );
      expect(_fdt[0].toString(), contains('192.168.1.10:47808'));
      expect(() => BacnetBdtEntry('10.0.0'), throwsArgumentError);
      expect(
        () => BacnetBdtEntry('10.0.0.1', mask: '255.255.0'),
        throwsArgumentError,
      );
      expect(
        BacnetBvlcResult.getName(0x0050),
        'Delete Foreign Device Table Entry NAK',
      );
      expect(BacnetBvlcResult.getName(0x0099), 'BVLC Result 0x0099');
    });
  });

  group('BacnetBbmdClient', () {
    late _FakeBbmd bbmd;
    var bdt = <BacnetBdtEntry>[];

    setUp(() async {
      bdt = List.of(_bdt);
      bbmd = await _FakeBbmd.bind((request, _) {
        final bvll = decodeBvlc(request);
        return switch (bvll.function) {
          BvlcFunction.readBroadcastDistributionTable => [
            encodeBvlc(
              BvlcFunction.readBroadcastDistributionTableAck,
              encodeBroadcastDistributionTable(bdt),
            ),
          ],
          BvlcFunction.writeBroadcastDistributionTable => [
            () {
              bdt = decodeBroadcastDistributionTable(bvll.data);
              return hexBytes(_resultOk);
            }(),
          ],
          BvlcFunction.readForeignDeviceTable => [hexBytes(_readFdtAck)],
          BvlcFunction.deleteForeignDeviceTableEntry => [
            hexBytes(bvll.data[3] == 1 ? _resultOk : '810000060050'),
          ],
          _ => [],
        };
      });
    });
    tearDown(() => bbmd.close());

    BacnetBbmdClient client({int retries = 2}) => BacnetBbmdClient(
      '127.0.0.1',
      port: bbmd.port,
      timeout: const Duration(milliseconds: 200),
      retries: retries,
    );

    test('reads and writes the Broadcast Distribution Table', () async {
      expect(await client().readBroadcastDistributionTable(), _bdt);
      final peers = [BacnetBdtEntry('127.0.0.1', port: 47900)];
      await client().writeBroadcastDistributionTable(peers);
      expect(await client().readBroadcastDistributionTable(), peers);
      expect(bbmd.requests[1], hexBytes('8101000e7f000001bb1cffffffff'));
    });

    test('reads the Foreign Device Table and deletes entries', () async {
      expect(await client().readForeignDeviceTable(), _fdt);
      await client().deleteForeignDeviceTableEntry('10.0.0.1', port: 47809);
      expect(bbmd.requests.last, hexBytes(_deleteFdtEntry));
      await expectLater(
        client().deleteForeignDeviceTableEntry('10.0.0.2'),
        throwsA(
          isA<BacnetBbmdException>().having(
            (e) => e.result,
            'result',
            BacnetBvlcResult.deleteForeignDeviceTableEntryNak,
          ),
        ),
      );
    });

    test('a refusal throws BacnetBbmdException', () async {
      final device = await _FakeBbmd.bind(
        (_, _) => [hexBytes(_resultReadBdtNak)],
      );
      addTearDown(device.close);
      await expectLater(
        BacnetBbmdClient(
          '127.0.0.1',
          port: device.port,
        ).readBroadcastDistributionTable(),
        throwsA(
          isA<BacnetBbmdException>().having(
            (e) => e.result,
            'result',
            BacnetBvlcResult.readBroadcastDistributionTableNak,
          ),
        ),
      );
    });

    test('repeats unanswered requests, then times out', () async {
      var calls = 0;
      final flaky = await _FakeBbmd.bind((request, _) {
        // answers the third request only
        if (++calls < 3) return [];
        return [hexBytes(_readBdtAckEmpty)];
      });
      addTearDown(flaky.close);
      BacnetBbmdClient flakyClient(int retries) => BacnetBbmdClient(
        '127.0.0.1',
        port: flaky.port,
        timeout: const Duration(milliseconds: 100),
        retries: retries,
      );
      expect(await flakyClient(2).readBroadcastDistributionTable(), isEmpty);
      expect(flaky.requests, hasLength(3));

      calls = -100;
      await expectLater(
        flakyClient(1).readForeignDeviceTable(),
        throwsA(isA<BacnetTimeoutException>()),
      );
    });

    test('ignores answers of other senders and other functions', () async {
      final other = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(other.close);
      final quiet = await _FakeBbmd.bind((request, clientPort) {
        // an answer from another socket, one of another function, then the
        // right one
        sendDatagram(
          other,
          hexBytes(_readBdtAckEmpty),
          InternetAddress.loopbackIPv4,
          clientPort,
        );
        return [hexBytes(_readFdtAck), hexBytes(_readBdtAck)];
      });
      addTearDown(quiet.close);
      expect(
        await BacnetBbmdClient(
          '127.0.0.1',
          port: quiet.port,
        ).readBroadcastDistributionTable(),
        _bdt,
      );
    });
  });
}
