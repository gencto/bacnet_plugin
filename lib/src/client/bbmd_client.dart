/// @docImport 'bacnet_client.dart';
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../codec/bvlc.dart';
import '../core/exceptions.dart';
import '../core/ip_address.dart';
import '../models/bbmd.dart';

/// Thrown when a BBMD refuses a request with a BVLC-Result NAK, e.g. when
/// the device is not a BBMD.
class BacnetBbmdException extends BacnetException {
  /// Creates the exception.
  const BacnetBbmdException(super.message, {required this.result});

  /// The result code.
  final BacnetBvlcResult result;

  @override
  String toString() => 'BacnetBbmdException: $message (${result.label})';
}

/// Reads and changes the tables of a BBMD (BACnet/IP Broadcast Management
/// Device, ASHRAE 135 Annex J): its Broadcast Distribution Table (the peer
/// BBMDs) and its Foreign Device Table (the registered foreign devices).
///
/// It uses an own UDP socket for each request, so it needs neither a
/// started [BacnetClient] nor the native stack:
///
/// ```dart
/// final bbmd = BacnetBbmdClient('192.168.1.1');
/// for (final peer in await bbmd.readBroadcastDistributionTable()) {
///   print('${peer.ipAddress}:${peer.port} mask ${peer.mask}');
/// }
/// for (final device in await bbmd.readForeignDeviceTable()) {
///   print('${device.ipAddress}:${device.port} ${device.remaining}s left');
/// }
/// ```
///
/// Requests are repeated [retries] times when the BBMD does not answer
/// within [timeout] ([BacnetTimeoutException] after the last one); a
/// refusal throws a [BacnetBbmdException].
final class BacnetBbmdClient {
  /// Creates a client for the BBMD at [host] (an IPv4 address or a host
  /// name) and [port].
  BacnetBbmdClient(
    this.host, {
    this.port = 47808,
    this.timeout = const Duration(seconds: 2),
    this.retries = 2,
  }) {
    RangeError.checkValueInInterval(port, 0, 0xFFFF, 'port');
    RangeError.checkNotNegative(retries, 'retries');
  }

  /// The BBMD.
  final String host;

  /// UDP port of the BBMD.
  final int port;

  /// Time to wait for each answer.
  final Duration timeout;

  /// Repetitions of an unanswered request.
  final int retries;

  /// Reads the Broadcast Distribution Table: the BBMDs the broadcasts of
  /// the network are forwarded to (including the BBMD itself).
  Future<List<BacnetBdtEntry>> readBroadcastDistributionTable() async {
    final answer = await _request(
      BvlcFunction.readBroadcastDistributionTable,
      const [],
      BvlcFunction.readBroadcastDistributionTableAck,
    );
    return decodeBroadcastDistributionTable(answer);
  }

  /// Replaces the Broadcast Distribution Table with [entries] (the BBMD
  /// must allow it, many refuse).
  Future<void> writeBroadcastDistributionTable(
    List<BacnetBdtEntry> entries,
  ) async {
    await _request(
      BvlcFunction.writeBroadcastDistributionTable,
      encodeBroadcastDistributionTable(entries),
      BvlcFunction.result,
    );
  }

  /// Reads the Foreign Device Table: the devices registered with the BBMD.
  Future<List<BacnetFdtEntry>> readForeignDeviceTable() async {
    final answer = await _request(
      BvlcFunction.readForeignDeviceTable,
      const [],
      BvlcFunction.readForeignDeviceTableAck,
    );
    return decodeForeignDeviceTable(answer);
  }

  /// Removes the foreign device at [ipAddress] and [port] from the Foreign
  /// Device Table.
  Future<void> deleteForeignDeviceTableEntry(
    String ipAddress, {
    int port = 47808,
  }) async {
    final address = await resolveBacnetIp(ipAddress, port);
    await _request(
      BvlcFunction.deleteForeignDeviceTableEntry,
      address,
      BvlcFunction.result,
    );
  }

  /// Sends [function] with [data] and returns the data of the answer
  /// [answerFunction]; a BVLC-Result other than success is a refusal.
  Future<Uint8List> _request(
    int function,
    List<int> data,
    int answerFunction,
  ) async {
    final target = await resolveBacnetIp(host, port);
    final address = InternetAddress.fromRawAddress(target.sublist(0, 4));
    final request = encodeBvlc(function, data);
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    Completer<(int, Uint8List)>? pending;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      final answer = pending;
      if (datagram == null ||
          answer == null ||
          answer.isCompleted ||
          datagram.address != address ||
          datagram.port != port) {
        return;
      }
      try {
        final bvll = decodeBvlc(datagram.data);
        if (bvll.function == answerFunction ||
            bvll.function == BvlcFunction.result) {
          answer.complete((bvll.function, Uint8List.fromList(bvll.data)));
        }
      } on BacnetDecodeException {
        // not an answer
      }
    });
    try {
      for (var attempt = 0; attempt <= retries; attempt++) {
        final answer = pending = Completer<(int, Uint8List)>();
        await _send(socket, request, address);
        final int function;
        final Uint8List answerData;
        try {
          (function, answerData) = await answer.future.timeout(timeout);
        } on TimeoutException {
          continue;
        }
        if (function != BvlcFunction.result) return answerData;
        final result = decodeBvlcResult(answerData);
        if (result == BacnetBvlcResult.successfulCompletion &&
            answerFunction == BvlcFunction.result) {
          return answerData;
        }
        throw BacnetBbmdException(
          'BBMD $host:$port refused the request',
          result: result,
        );
      }
      throw BacnetTimeoutException('BBMD $host:$port did not answer');
    } finally {
      socket.close();
    }
  }

  /// Sends [data] to the BBMD. `send` returns 0 while the datagram would
  /// block (on Windows while the previous one is still being sent): retry.
  Future<void> _send(
    RawDatagramSocket socket,
    List<int> data,
    InternetAddress address,
  ) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (socket.send(data, address, port) > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    // not sent: the attempt times out and is repeated
  }
}
