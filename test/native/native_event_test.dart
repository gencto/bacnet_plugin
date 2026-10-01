import 'dart:typed_data';

import 'package:bacnet_plugin/src/native/bindings.g.dart';
import 'package:bacnet_plugin/src/native/native_event.dart';
import 'package:test/test.dart';

/// Builds one record of the native event buffer.
Uint8List event({
  required int kind,
  int service = 0,
  int invokeId = 0,
  int flags = 0,
  int deviceId = BP_DEVICE_UNKNOWN,
  int a = 0,
  int b = 0,
  int c = 0,
  int d = 0,
  int priority = 0,
  int network = 0,
  List<int> mac = const [],
  List<int> adr = const [],
  List<int> data = const [],
}) {
  final header = ByteData(NativeEvent.headerSize)
    ..setUint8(0, kind)
    ..setUint8(1, service)
    ..setUint8(2, invokeId)
    ..setUint8(3, flags)
    ..setUint32(4, deviceId, Endian.host)
    ..setUint32(8, a, Endian.host)
    ..setUint32(12, b, Endian.host)
    ..setUint32(16, c, Endian.host)
    ..setInt32(20, d, Endian.host)
    ..setUint8(24, priority)
    ..setUint8(25, mac.length)
    ..setUint16(26, network, Endian.host)
    ..setUint8(35, adr.length)
    ..setUint16(44, data.length, Endian.host);
  for (var i = 0; i < mac.length; i++) {
    header.setUint8(28 + i, mac[i]);
  }
  for (var i = 0; i < adr.length; i++) {
    header.setUint8(36 + i, adr[i]);
  }
  return Uint8List.fromList([...header.buffer.asUint8List(), ...data]);
}

void main() {
  group('readNativeEvents', () {
    test('returns nothing for an empty buffer', () {
      expect(readNativeEvents(Uint8List(0)), isEmpty);
    });

    test('decodes header fields and payload', () {
      final buffer = event(
        kind: BP_EVENT_WRITE,
        service: 15,
        invokeId: 9,
        flags: BP_FLAG_COMPLEX | BP_FLAG_LOCAL,
        deviceId: 1234,
        a: 2,
        b: 3,
        c: 85,
        d: -1,
        priority: 8,
        network: 0xFFFF,
        mac: [192, 168, 1, 10, 0xBA, 0xC0],
        adr: [5],
        data: [0x44, 0x41, 0xAC, 0x00, 0x00],
      );
      final events = readNativeEvents(buffer).toList();
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.kind, BP_EVENT_WRITE);
      expect(e.service, 15);
      expect(e.invokeId, 9);
      expect(e.hasFlag(BP_FLAG_COMPLEX), isTrue);
      expect(e.hasFlag(BP_FLAG_ABORT_FROM_SERVER), isFalse);
      expect(e.deviceId, 1234);
      expect((e.a, e.b, e.c, e.d), (2, 3, 85, -1));
      expect(e.priority, 8);
      expect(e.sourceNetwork, 0xFFFF);
      expect(e.sourceMac, [192, 168, 1, 10, 0xBA, 0xC0]);
      expect(e.sourceAdr, [5]);
      expect(e.data, [0x44, 0x41, 0xAC, 0x00, 0x00]);
    });

    test('iterates over consecutive records', () {
      final buffer = Uint8List.fromList([
        ...event(kind: BP_EVENT_SIMPLE_ACK, invokeId: 1),
        ...event(kind: BP_EVENT_LOG, a: 2, data: 'hello'.codeUnits),
        ...event(kind: BP_EVENT_TIMEOUT, invokeId: 3),
      ]);
      final events = readNativeEvents(buffer).toList();
      expect(events.map((e) => e.kind), [
        BP_EVENT_SIMPLE_ACK,
        BP_EVENT_LOG,
        BP_EVENT_TIMEOUT,
      ]);
      expect(String.fromCharCodes(events[1].data), 'hello');
      expect(events[2].invokeId, 3);
    });

    test('ignores a truncated trailing record', () {
      final complete = event(kind: BP_EVENT_SIMPLE_ACK, invokeId: 1);
      final truncated = event(kind: BP_EVENT_UNCONFIRMED, data: [1, 2, 3]);
      final buffer = Uint8List.fromList([
        ...complete,
        ...truncated.sublist(0, truncated.length - 1),
      ]);
      expect(readNativeEvents(buffer).map((e) => e.invokeId), [1]);
    });

    test('clamps address lengths to the header fields', () {
      final buffer = event(kind: BP_EVENT_UNCONFIRMED)..[25] = 200;
      expect(readNativeEvents(buffer).single.sourceMac, hasLength(7));
    });
  });
}
