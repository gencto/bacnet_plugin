import 'dart:io';
import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/requests.dart';
import 'package:bacnet_plugin/src/codec/responses.dart';

/// A minimal BACnet/IP device with SubscribeCOVPropertyMultiple (ASHRAE 135
/// clause 13.16), which bacnet-stack does not implement: it acknowledges
/// the subscriptions (or refuses the properties in [refused] with a
/// SubscribeCOVPropertyMultiple-Error) and sends COVNotificationMultiple
/// when the test calls [notify].
final class CovMultipleDevice {
  CovMultipleDevice._(this._socket, this.deviceId, this.refused) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket.receive();
      if (datagram != null) _onDatagram(datagram);
    });
  }

  /// Binds the device to an ephemeral port on the loopback interface.
  static Future<CovMultipleDevice> bind({
    required int deviceId,
    Set<BacnetPropertyId> refused = const {},
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return CovMultipleDevice._(socket, deviceId, refused);
  }

  final RawDatagramSocket _socket;

  /// Device instance.
  final int deviceId;

  /// Properties whose subscription the device refuses (unknown property).
  final Set<BacnetPropertyId> refused;

  /// The SubscribeCOVPropertyMultiple requests received.
  final List<SubscribeCovPropertyMultipleData> subscriptions = [];

  /// Invoke ids of the confirmed notifications the client acknowledged.
  final List<int> acknowledged = [];

  InternetAddress? _subscriber;
  int? _subscriberPort;
  int _invokeId = 0;

  /// UDP port of the device.
  int get port => _socket.port;

  /// Stops the device.
  void close() => _socket.close();

  /// Sends a COVNotificationMultiple with [notifications] to the last
  /// subscriber; returns the invoke id of a confirmed one.
  int notify(
    List<CovObjectNotification> notifications, {
    required bool confirmed,
    int timeRemaining = 300,
    BacnetDateTime? timestamp,
  }) {
    final request = subscriptions.last;
    final payload = encodeCovNotificationMultiple(
      subscriberProcessId: request.subscriberProcessId,
      initiatingDeviceId: deviceId,
      timeRemaining: timeRemaining,
      timestamp: timestamp,
      notifications: notifications,
    );
    final invokeId = _invokeId++ & 0xFF;
    _send(
      _subscriber!,
      _subscriberPort!,
      confirmed
          ? [0x00, 0x05, invokeId, 31, ...payload]
          : [0x10, 11, ...payload],
    );
    return invokeId;
  }

  void _onDatagram(Datagram datagram) {
    final data = datagram.data;
    if (data.length < 6 || data[0] != 0x81 || data[4] != 0x01) return;
    // no routing information in the tests
    if (data[5] & 0xA8 != 0) return;
    final apdu = Uint8List.sublistView(data, 6);
    if (apdu.isEmpty) return;
    switch (apdu[0] & 0xF0) {
      case 0x00 when apdu.length >= 4 && apdu[3] == 30:
        _onSubscribe(apdu, datagram.address, datagram.port);
      case 0x20 when apdu.length >= 3 && apdu[2] == 31:
        acknowledged.add(apdu[1]);
    }
  }

  void _onSubscribe(Uint8List apdu, InternetAddress address, int port) {
    final invokeId = apdu[2];
    final request = decodeSubscribeCovPropertyMultiple(
      Uint8List.sublistView(apdu, 4),
    );
    subscriptions.add(request);
    _subscriber = address;
    _subscriberPort = port;
    for (final specification in request.specifications) {
      for (final reference in specification.references) {
        if (!refused.contains(reference.property)) continue;
        final object = specification.object;
        final property = reference.property;
        final error = BytesBuilder()
          // error-type: services, other
          ..add([0x0E, 0x91, 0x05, 0x91, 0x00, 0x0F])
          ..add([0x1E, 0x0C, ..._objectId(object.type, object.instance)])
          ..add([0x1E, 0x09, property, 0x1F])
          // property, unknown-property
          ..add([0x2E, 0x91, 0x02, 0x91, 0x20, 0x2F, 0x1F]);
        _send(address, port, [0x50, invokeId, 30, ...error.toBytes()]);
        return;
      }
    }
    _send(address, port, [0x20, invokeId, 30]);
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

  void _send(InternetAddress address, int port, List<int> apdu) {
    final length = 4 + 2 + apdu.length;
    _socket.send(
      [0x81, 0x0A, length >> 8, length & 0xFF, 0x01, 0x00, ...apdu],
      address,
      port,
    );
  }
}
