import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'udp.dart';

/// A minimal BACnet/IP device that answers every ReadProperty with the
/// object list of [objectCount] Analog Values, sent as segmented
/// ComplexACK (ASHRAE 135 clause 5.4.5, server in SEGMENTED_RESPONSE).
///
/// It tests the client's reassembly and is not a general server:
/// - segments carry at most [segmentSize] bytes of service data and are
///   sent in windows of [window] segments, each window after a SegmentACK;
/// - segments listed in [dropOnce] are left out the first time (the client
///   must answer with a negative SegmentACK);
/// - with [stallAfter] the device stops after that segment (the client
///   must time out).
final class SegmentingDevice {
  SegmentingDevice._(
    this._socket,
    this.deviceId,
    this.objectCount,
    this.segmentSize,
    this.window,
    this.dropOnce,
    this.stallAfter,
  ) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket.receive();
      if (datagram != null) _onDatagram(datagram);
    });
  }

  /// Binds the device to an ephemeral port on the loopback interface.
  static Future<SegmentingDevice> bind({
    required int deviceId,
    int objectCount = 300,
    int segmentSize = 200,
    int window = 3,
    Set<int> dropOnce = const {},
    int? stallAfter,
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return SegmentingDevice._(
      socket,
      deviceId,
      objectCount,
      segmentSize,
      window,
      {...dropOnce},
      stallAfter,
    );
  }

  final RawDatagramSocket _socket;

  /// Device instance.
  final int deviceId;

  /// Number of objects in the answer.
  final int objectCount;

  /// Service data bytes per segment.
  final int segmentSize;

  /// Proposed window size.
  final int window;

  /// Segments not sent the first time.
  final Set<int> dropOnce;

  /// Last segment sent before the device goes silent.
  final int? stallAfter;

  /// Segment acknowledgements received: (negative, sequence number).
  final List<(bool, int)> acks = [];

  /// Whether the requests asked for segmented answers.
  final List<bool> segmentationAccepted = [];

  _Transfer? _transfer;

  /// UDP port of the device.
  int get port => _socket.port;

  /// Stops the device.
  void close() => _socket.close();

  /// The service data of the answer: ReadProperty-ACK with the object list.
  Uint8List get answer {
    final out = BytesBuilder()
      ..add([0x0C, ..._objectId(8, deviceId)])
      ..add([0x19, 76])
      ..addByte(0x3E);
    for (var i = 0; i < objectCount; i++) {
      out.add([0xC4, ..._objectId(2, i)]);
    }
    out.addByte(0x3F);
    return out.toBytes();
  }

  static List<int> _objectId(int type, int instance) {
    final value = (type << 22) | instance;
    return [
      value >> 24,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
  }

  void _onDatagram(Datagram datagram) {
    final data = datagram.data;
    // BVLC: 0x81, function, length
    if (data.length < 6 || data[0] != 0x81) return;
    final apduOffset = _apduOffset(data, 4);
    if (apduOffset == null || apduOffset >= data.length) return;
    final apdu = Uint8List.sublistView(data, apduOffset);
    switch (apdu[0] & 0xF0) {
      case 0x00 when apdu.length >= 4:
        _onRequest(apdu, datagram.address, datagram.port);
      case 0x40 when apdu.length >= 4:
        _onSegmentAck(apdu);
    }
  }

  /// Skips the NPDU header starting at [offset].
  static int? _apduOffset(Uint8List data, int offset) {
    if (data[offset] != 0x01) return null;
    final control = data[offset + 1];
    if (control & 0x80 != 0) return null; // network layer message
    var i = offset + 2;
    if (control & 0x20 != 0) i += 3 + data[i + 2]; // DNET, DLEN, DADR
    if (control & 0x08 != 0) i += 3 + data[i + 2]; // SNET, SLEN, SADR
    if (control & 0x20 != 0) i += 1; // hop count
    return i;
  }

  void _onRequest(Uint8List apdu, InternetAddress address, int port) {
    final accepted = apdu[0] & 0x02 != 0;
    segmentationAccepted.add(accepted);
    final invokeId = apdu[2];
    if (!accepted) {
      // Abort, server, segmentation-not-supported
      _send(address, port, [0x71, invokeId, 4]);
      return;
    }
    final body = answer;
    final segments = <Uint8List>[
      for (var i = 0; i < body.length; i += segmentSize)
        Uint8List.sublistView(
          body,
          i,
          i + segmentSize < body.length ? i + segmentSize : body.length,
        ),
    ];
    _transfer = _Transfer(address, port, invokeId, apdu[3], segments);
    _sendSegment(0);
  }

  void _onSegmentAck(Uint8List apdu) {
    final transfer = _transfer;
    if (transfer == null || apdu[1] != transfer.invokeId) return;
    final negative = apdu[0] & 0x02 != 0;
    final sequence = apdu[2];
    acks.add((negative, sequence));
    if (!negative && sequence == transfer.segments.length - 1) {
      _transfer = null;
      return;
    }
    final first = sequence + 1;
    for (
      var i = first;
      i < first + window && i < transfer.segments.length;
      i++
    ) {
      _sendSegment(i);
    }
  }

  void _sendSegment(int sequence) {
    final transfer = _transfer!;
    if (stallAfter case final last? when sequence > last) return;
    if (dropOnce.remove(sequence)) return;
    final more = sequence < transfer.segments.length - 1;
    _send(transfer.address, transfer.port, [
      0x38 | (more ? 0x04 : 0), // ComplexACK, segmented, more follows
      transfer.invokeId,
      sequence,
      window,
      transfer.service,
      ...transfer.segments[sequence],
    ]);
  }

  void _send(InternetAddress address, int port, List<int> apdu) {
    final length = 4 + 2 + apdu.length;
    sendDatagram(
      _socket,
      [0x81, 0x0A, length >> 8, length & 0xFF, 0x01, 0x00, ...apdu],
      address,
      port,
    );
  }
}

final class _Transfer {
  _Transfer(
    this.address,
    this.port,
    this.invokeId,
    this.service,
    this.segments,
  );

  final InternetAddress address;
  final int port;
  final int invokeId;
  final int service;
  final List<Uint8List> segments;
}
