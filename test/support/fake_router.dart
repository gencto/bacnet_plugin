import 'dart:io';
import 'dart:typed_data';

import 'udp.dart';

/// A network layer message received by a [FakeRouter].
typedef ReceivedNetworkMessage = ({
  int bvlcFunction,
  int type,
  int? destinationNetwork,
  bool expectingReply,
  List<int> data,
});

/// A minimal BACnet/IP router on an ephemeral loopback port: answers
/// Who-Is-Router-To-Network, What-Is-Network-Number and routing table
/// queries sent to it (always with a unicast to the sender).
final class FakeRouter {
  FakeRouter._(this._socket, this.networks, this.networkNumber) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket.receive();
      if (datagram != null) _onDatagram(datagram);
    });
  }

  /// Binds the router to an ephemeral port on the loopback interface.
  static Future<FakeRouter> bind({
    required List<int> networks,
    int? networkNumber,
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return FakeRouter._(socket, networks, networkNumber);
  }

  final RawDatagramSocket _socket;
  RawDatagramSocket? _broadcasts;

  /// Also receives the broadcasts of the loopback network (127.255.255.255)
  /// to [port], sharing the port with the client. False where the system
  /// does not allow it.
  Future<bool> listenForBroadcasts(int port) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress('127.255.255.255'),
        port, // SO_REUSEADDR by default: shares the port with the client
      );
      _broadcasts = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram != null) _onDatagram(datagram);
      });
      return true;
    } on SocketException {
      return false;
    }
  }

  /// Networks announced in I-Am-Router-To-Network.
  final List<int> networks;

  /// Answer to What-Is-Network-Number (null: no answer).
  final int? networkNumber;

  /// Messages received, oldest first.
  final List<ReceivedNetworkMessage> received = [];

  /// Port the router listens on.
  int get port => _socket.port;

  /// Sends [type] with [data] to [port] on the loopback interface.
  void send(int port, int type, List<int> data) {
    sendDatagram(
      _socket,
      _bvlc([0x01, 0x80, type, ...data]),
      InternetAddress.loopbackIPv4,
      port,
    );
  }

  void close() {
    _socket.close();
    _broadcasts?.close();
  }

  void _onDatagram(Datagram datagram) {
    final message = _parse(datagram.data);
    if (message == null) return;
    received.add(message);
    final answer = switch (message.type) {
      // Who-Is-Router-To-Network: all networks, or the one asked for
      0x00 when message.data.length >= 2 =>
        networks.contains((message.data[0] << 8) | message.data[1])
            ? (0x01, message.data.sublist(0, 2))
            : null,
      0x00 => (
        0x01,
        [
          for (final n in networks) ...[n >> 8, n & 0xFF],
        ],
      ),
      // Initialize-Routing-Table query: one port per network
      0x06 when message.data.isNotEmpty && message.data[0] == 0 => (
        0x07,
        [
          networks.length,
          for (final (i, n) in networks.indexed) ...[
            n >> 8,
            n & 0xFF,
            i + 1,
            0,
          ],
        ],
      ),
      // What-Is-Network-Number
      0x12 when networkNumber != null => (
        0x13,
        [networkNumber! >> 8, networkNumber! & 0xFF, 1],
      ),
      _ => null,
    };
    if (answer case (final type, final data)) {
      sendDatagram(
        _socket,
        _bvlc([0x01, 0x80, type, ...data]),
        datagram.address,
        datagram.port,
      );
    }
  }

  static Uint8List _bvlc(List<int> npdu) {
    final length = npdu.length + 4;
    return Uint8List.fromList([
      0x81,
      0x0A,
      length >> 8,
      length & 0xFF,
      ...npdu,
    ]);
  }

  static ReceivedNetworkMessage? _parse(Uint8List packet) {
    if (packet.length < 6 || packet[0] != 0x81) return null;
    final function = packet[1];
    // Forwarded-NPDU carries the original source address
    var offset = function == 0x04 ? 10 : 4;
    if (packet.length < offset + 2 || packet[offset] != 0x01) return null;
    final control = packet[offset + 1];
    if (control & 0x80 == 0) return null;
    offset += 2;
    int? dnet;
    if (control & 0x20 != 0) {
      dnet = (packet[offset] << 8) | packet[offset + 1];
      offset += 3 + packet[offset + 2];
    }
    if (control & 0x08 != 0) offset += 3 + packet[offset + 2];
    if (control & 0x20 != 0) offset++; // hop count
    if (offset >= packet.length) return null;
    final type = packet[offset++];
    if (type >= 0x80) offset += 2;
    return (
      bvlcFunction: function,
      type: type,
      destinationNetwork: dnet,
      expectingReply: control & 0x04 != 0,
      data: packet.sublist(offset),
    );
  }
}
