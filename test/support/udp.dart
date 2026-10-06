import 'dart:async';
import 'dart:io';

final _queues = Expando<Future<void>>();

/// Sends [data] from [socket] after the datagrams queued before it.
///
/// `RawDatagramSocket.send` returns 0 when the datagram would block, and on
/// Windows it does so while the previous datagram is still being sent:
/// datagrams sent one after another are dropped unless they are retried.
void sendDatagram(
  RawDatagramSocket socket,
  List<int> data,
  InternetAddress address,
  int port,
) {
  final previous = _queues[socket] ?? Future<void>.value();
  _queues[socket] = previous.then((_) async {
    for (var attempt = 0; attempt < 1000; attempt++) {
      try {
        if (socket.send(data, address, port) > 0) return;
      } on SocketException {
        return; // closed
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  });
}
