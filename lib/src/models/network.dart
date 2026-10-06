/// @docImport '../client/bacnet_client.dart';
/// @docImport '../utilities/network_discovery.dart';
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../constants/enumerations.dart';
import '../core/exceptions.dart';
import 'construct_support.dart';

/// A network layer message (clause 6.4): how routers announce the networks
/// they reach, report problems and tell the local network number.
///
/// Received messages arrive as `NetworkMessageEvent`s
/// ([BacnetClient.networkMessages]); [BacnetClient.sendNetworkMessage]
/// sends one. The class is sealed, so a `switch` over the message type is
/// checked for exhaustiveness:
///
/// ```dart
/// client.networkMessages.listen((event) {
///   switch (event.message) {
///     case BacnetIAmRouterToNetwork(:final networks):
///       print('${event.ipAddress} routes to $networks');
///     case BacnetRejectMessageToNetwork(:final reason, :final network):
///       print('network $network unreachable: ${reason.label}');
///     case _:
///   }
/// });
/// ```
@immutable
sealed class BacnetNetworkMessage {
  const BacnetNetworkMessage();

  /// Decodes a message of [type] from [data], the octets after the message
  /// type (and after the vendor id of proprietary messages). Throws a
  /// [BacnetDecodeException] if it is malformed.
  factory BacnetNetworkMessage.decode(
    BacnetNetworkMessageType type,
    List<int> data, {
    int vendorId = 0,
  }) {
    final bytes = Uint8List.fromList(data);
    BacnetDecodeException malformed() => BacnetDecodeException(
      'malformed ${type.label} message (${bytes.length} octets)',
    );
    // a network number: 1..65534
    int net(int offset) {
      final network = (bytes[offset] << 8) | bytes[offset + 1];
      if (network == 0 || network == 0xFFFF) throw malformed();
      return network;
    }

    List<int> networks() {
      if (bytes.length.isOdd) throw malformed();
      return [for (var i = 0; i < bytes.length; i += 2) net(i)];
    }

    return _decode(type, bytes, vendorId, malformed, net, networks);
  }

  static BacnetNetworkMessage _decode(
    BacnetNetworkMessageType type,
    Uint8List bytes,
    int vendorId,
    BacnetDecodeException Function() malformed,
    int Function(int offset) net,
    List<int> Function() networks,
  ) {
    switch (type) {
      case BacnetNetworkMessageType.whoIsRouterToNetwork:
        if (bytes.length == 1) throw malformed();
        return BacnetWhoIsRouterToNetwork(
          network: bytes.length >= 2 ? net(0) : null,
        );
      case BacnetNetworkMessageType.iAmRouterToNetwork:
        return BacnetIAmRouterToNetwork(networks());
      case BacnetNetworkMessageType.iCouldBeRouterToNetwork:
        if (bytes.length < 3) throw malformed();
        return BacnetICouldBeRouterToNetwork(
          network: net(0),
          performanceIndex: bytes[2],
        );
      case BacnetNetworkMessageType.rejectMessageToNetwork:
        if (bytes.length < 3) throw malformed();
        return BacnetRejectMessageToNetwork(
          reason: BacnetNetworkRejectReason(bytes[0]),
          network: (bytes[1] << 8) | bytes[2],
        );
      case BacnetNetworkMessageType.routerBusyToNetwork:
        return BacnetRouterBusyToNetwork(networks());
      case BacnetNetworkMessageType.routerAvailableToNetwork:
        return BacnetRouterAvailableToNetwork(networks());
      case BacnetNetworkMessageType.initializeRoutingTable:
        return BacnetInitializeRoutingTable(_routingTable(bytes, malformed));
      case BacnetNetworkMessageType.initializeRoutingTableAck:
        return BacnetInitializeRoutingTableAck(_routingTable(bytes, malformed));
      case BacnetNetworkMessageType.whatIsNetworkNumber:
        return const BacnetWhatIsNetworkNumber();
      case BacnetNetworkMessageType.networkNumberIs:
        if (bytes.length < 3) throw malformed();
        return BacnetNetworkNumberIs(
          network: net(0),
          configured: bytes[2] == 1,
        );
    }
    return BacnetOtherNetworkMessage(type, bytes, vendorId: vendorId);
  }

  /// The message type.
  BacnetNetworkMessageType get type;

  /// Vendor of a proprietary message (type 0x80 and above), else 0.
  int get vendorId => 0;

  /// The octets after the message type.
  Uint8List encode();

  static List<BacnetRoutingTableEntry> _routingTable(
    Uint8List bytes,
    BacnetDecodeException Function() malformed,
  ) {
    if (bytes.isEmpty) throw malformed();
    final count = bytes[0];
    final entries = <BacnetRoutingTableEntry>[];
    var offset = 1;
    for (var i = 0; i < count; i++) {
      if (offset + 4 > bytes.length) throw malformed();
      final network = (bytes[offset] << 8) | bytes[offset + 1];
      final infoLength = bytes[offset + 3];
      if (network == 0 ||
          network == 0xFFFF ||
          offset + 4 + infoLength > bytes.length) {
        throw malformed();
      }
      entries.add(
        BacnetRoutingTableEntry(
          network: network,
          portId: bytes[offset + 2],
          portInfo: Uint8List.sublistView(
            bytes,
            offset + 4,
            offset + 4 + infoLength,
          ),
        ),
      );
      offset += 4 + infoLength;
    }
    return List.unmodifiable(entries);
  }
}

void _checkNetwork(int network, {bool broadcast = false}) {
  if (network < 1 || network > (broadcast ? 0xFFFF : 0xFFFE)) {
    throw ArgumentError.value(network, 'network', 'not a network number');
  }
}

Uint8List _encodeNetworks(List<int> networks) {
  final bytes = Uint8List(networks.length * 2);
  for (var i = 0; i < networks.length; i++) {
    bytes[2 * i] = networks[i] >> 8;
    bytes[2 * i + 1] = networks[i] & 0xFF;
  }
  return bytes;
}

String _networks(List<int> networks) =>
    networks.isEmpty ? 'all networks' : 'networks ${networks.join(', ')}';

/// Asks which router reaches [network], or for all routers and the
/// networks they reach when [network] is null.
final class BacnetWhoIsRouterToNetwork extends BacnetNetworkMessage {
  /// Creates the message.
  BacnetWhoIsRouterToNetwork({this.network}) {
    if (network case final network?) _checkNetwork(network);
  }

  /// The wanted network, null for all.
  final int? network;

  @override
  BacnetNetworkMessageType get type =>
      BacnetNetworkMessageType.whoIsRouterToNetwork;

  @override
  Uint8List encode() => switch (network) {
    final network? => _encodeNetworks([network]),
    null => Uint8List(0),
  };

  @override
  bool operator ==(Object other) =>
      other is BacnetWhoIsRouterToNetwork && other.network == network;

  @override
  int get hashCode => Object.hash(type, network);

  @override
  String toString() =>
      'BacnetWhoIsRouterToNetwork(${network ?? 'all networks'})';
}

/// A router announces the networks it reaches.
final class BacnetIAmRouterToNetwork extends BacnetNetworkMessage {
  /// Creates the message.
  BacnetIAmRouterToNetwork(List<int> networks)
    : networks = List.unmodifiable(networks) {
    networks.forEach(_checkNetwork);
  }

  /// The networks the router reaches.
  final List<int> networks;

  @override
  BacnetNetworkMessageType get type =>
      BacnetNetworkMessageType.iAmRouterToNetwork;

  @override
  Uint8List encode() => _encodeNetworks(networks);

  @override
  bool operator ==(Object other) =>
      other is BacnetIAmRouterToNetwork && listEquals(other.networks, networks);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(networks));

  @override
  String toString() => 'BacnetIAmRouterToNetwork(${_networks(networks)})';
}

/// A half router could establish a connection to [network].
final class BacnetICouldBeRouterToNetwork extends BacnetNetworkMessage {
  /// Creates the message.
  BacnetICouldBeRouterToNetwork({
    required this.network,
    required this.performanceIndex,
  }) {
    _checkNetwork(network);
    RangeError.checkValueInInterval(
      performanceIndex,
      0,
      255,
      'performanceIndex',
    );
  }

  /// The network.
  final int network;

  /// Performance of the connection (lower is better).
  final int performanceIndex;

  @override
  BacnetNetworkMessageType get type =>
      BacnetNetworkMessageType.iCouldBeRouterToNetwork;

  @override
  Uint8List encode() =>
      Uint8List.fromList([network >> 8, network & 0xFF, performanceIndex]);

  @override
  bool operator ==(Object other) =>
      other is BacnetICouldBeRouterToNetwork &&
      other.network == network &&
      other.performanceIndex == performanceIndex;

  @override
  int get hashCode => Object.hash(type, network, performanceIndex);

  @override
  String toString() =>
      'BacnetICouldBeRouterToNetwork($network, performance '
      '$performanceIndex)';
}

/// A router could not forward a message to [network].
final class BacnetRejectMessageToNetwork extends BacnetNetworkMessage {
  /// Creates the message.
  BacnetRejectMessageToNetwork({required this.reason, required this.network}) {
    RangeError.checkValueInInterval(reason, 0, 255, 'reason');
    RangeError.checkValueInInterval(network, 0, 0xFFFF, 'network');
  }

  /// Why the message was rejected.
  final BacnetNetworkRejectReason reason;

  /// The destination network of the rejected message.
  final int network;

  @override
  BacnetNetworkMessageType get type =>
      BacnetNetworkMessageType.rejectMessageToNetwork;

  @override
  Uint8List encode() =>
      Uint8List.fromList([reason, network >> 8, network & 0xFF]);

  @override
  bool operator ==(Object other) =>
      other is BacnetRejectMessageToNetwork &&
      other.reason == reason &&
      other.network == network;

  @override
  int get hashCode => Object.hash(type, reason, network);

  @override
  String toString() =>
      'BacnetRejectMessageToNetwork(${reason.label}, network $network)';
}

/// A router stops forwarding messages to [networks] (all of its networks
/// when empty) for a while.
final class BacnetRouterBusyToNetwork extends BacnetNetworkMessage {
  /// Creates the message.
  BacnetRouterBusyToNetwork(List<int> networks)
    : networks = List.unmodifiable(networks) {
    networks.forEach(_checkNetwork);
  }

  /// The networks, empty for all networks of the router.
  final List<int> networks;

  @override
  BacnetNetworkMessageType get type =>
      BacnetNetworkMessageType.routerBusyToNetwork;

  @override
  Uint8List encode() => _encodeNetworks(networks);

  @override
  bool operator ==(Object other) =>
      other is BacnetRouterBusyToNetwork &&
      listEquals(other.networks, networks);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(networks));

  @override
  String toString() => 'BacnetRouterBusyToNetwork(${_networks(networks)})';
}

/// A router forwards messages to [networks] (all of its networks when
/// empty) again.
final class BacnetRouterAvailableToNetwork extends BacnetNetworkMessage {
  /// Creates the message.
  BacnetRouterAvailableToNetwork(List<int> networks)
    : networks = List.unmodifiable(networks) {
    networks.forEach(_checkNetwork);
  }

  /// The networks, empty for all networks of the router.
  final List<int> networks;

  @override
  BacnetNetworkMessageType get type =>
      BacnetNetworkMessageType.routerAvailableToNetwork;

  @override
  Uint8List encode() => _encodeNetworks(networks);

  @override
  bool operator ==(Object other) =>
      other is BacnetRouterAvailableToNetwork &&
      listEquals(other.networks, networks);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(networks));

  @override
  String toString() => 'BacnetRouterAvailableToNetwork(${_networks(networks)})';
}

/// An entry of the routing table of a router: a network reached through
/// one of its ports.
@immutable
final class BacnetRoutingTableEntry {
  /// Creates an entry.
  BacnetRoutingTableEntry({
    required this.network,
    required this.portId,
    List<int> portInfo = const [],
  }) : portInfo = Uint8List.fromList(portInfo) {
    _checkNetwork(network);
    RangeError.checkValueInInterval(portId, 0, 255, 'portId');
    RangeError.checkValueInInterval(portInfo.length, 0, 255, 'portInfo');
  }

  /// The network.
  final int network;

  /// The port that reaches it (0: a network reached through another
  /// router).
  final int portId;

  /// Port specific information (often empty).
  final Uint8List portInfo;

  @override
  bool operator ==(Object other) =>
      other is BacnetRoutingTableEntry &&
      other.network == network &&
      other.portId == portId &&
      listEquals(other.portInfo, portInfo);

  @override
  int get hashCode => Object.hash(network, portId, Object.hashAll(portInfo));

  @override
  String toString() =>
      'BacnetRoutingTableEntry(network $network, port $portId'
      '${portInfo.isEmpty ? '' : ', info $portInfo'})';
}

Uint8List _encodeRoutingTable(List<BacnetRoutingTableEntry> entries) {
  final builder = BytesBuilder(copy: false)..addByte(entries.length);
  for (final entry in entries) {
    builder
      ..add([
        entry.network >> 8,
        entry.network & 0xFF,
        entry.portId,
        entry.portInfo.length,
      ])
      ..add(entry.portInfo);
  }
  return builder.takeBytes();
}

/// Updates the routing table of a router with [entries], or queries it
/// when empty (the router answers with a [BacnetInitializeRoutingTableAck]).
final class BacnetInitializeRoutingTable extends BacnetNetworkMessage {
  /// Creates the message.
  BacnetInitializeRoutingTable([
    List<BacnetRoutingTableEntry> entries = const [],
  ]) : entries = List.unmodifiable(entries) {
    RangeError.checkValueInInterval(entries.length, 0, 255, 'entries');
  }

  /// The entries, empty for a query.
  final List<BacnetRoutingTableEntry> entries;

  @override
  BacnetNetworkMessageType get type =>
      BacnetNetworkMessageType.initializeRoutingTable;

  @override
  Uint8List encode() => _encodeRoutingTable(entries);

  @override
  bool operator ==(Object other) =>
      other is BacnetInitializeRoutingTable &&
      listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(entries));

  @override
  String toString() => 'BacnetInitializeRoutingTable($entries)';
}

/// The routing table of a router, the answer to a query
/// ([BacnetInitializeRoutingTable] without entries).
final class BacnetInitializeRoutingTableAck extends BacnetNetworkMessage {
  /// Creates the message.
  BacnetInitializeRoutingTableAck([
    List<BacnetRoutingTableEntry> entries = const [],
  ]) : entries = List.unmodifiable(entries) {
    RangeError.checkValueInInterval(entries.length, 0, 255, 'entries');
  }

  /// The routing table.
  final List<BacnetRoutingTableEntry> entries;

  @override
  BacnetNetworkMessageType get type =>
      BacnetNetworkMessageType.initializeRoutingTableAck;

  @override
  Uint8List encode() => _encodeRoutingTable(entries);

  @override
  bool operator ==(Object other) =>
      other is BacnetInitializeRoutingTableAck &&
      listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(entries));

  @override
  String toString() => 'BacnetInitializeRoutingTableAck($entries)';
}

/// Asks for the number of the local network.
final class BacnetWhatIsNetworkNumber extends BacnetNetworkMessage {
  /// Creates the message.
  const BacnetWhatIsNetworkNumber();

  @override
  BacnetNetworkMessageType get type =>
      BacnetNetworkMessageType.whatIsNetworkNumber;

  @override
  Uint8List encode() => Uint8List(0);

  @override
  bool operator ==(Object other) => other is BacnetWhatIsNetworkNumber;

  @override
  int get hashCode => type.hashCode;

  @override
  String toString() => 'BacnetWhatIsNetworkNumber()';
}

/// The number of the local network.
final class BacnetNetworkNumberIs extends BacnetNetworkMessage {
  /// Creates the message.
  BacnetNetworkNumberIs({required this.network, this.configured = false}) {
    _checkNetwork(network);
  }

  /// The network number.
  final int network;

  /// True when the number is configured in the sender, false when the
  /// sender learned it from another device.
  final bool configured;

  @override
  BacnetNetworkMessageType get type => BacnetNetworkMessageType.networkNumberIs;

  @override
  Uint8List encode() => Uint8List.fromList([
    network >> 8,
    network & 0xFF,
    if (configured) 1 else 0,
  ]);

  @override
  bool operator ==(Object other) =>
      other is BacnetNetworkNumberIs &&
      other.network == network &&
      other.configured == configured;

  @override
  int get hashCode => Object.hash(type, network, configured);

  @override
  String toString() =>
      'BacnetNetworkNumberIs($network, '
      '${configured ? 'configured' : 'learned'})';
}

/// A message this library does not decode: proprietary messages, network
/// security and connection messages.
final class BacnetOtherNetworkMessage extends BacnetNetworkMessage {
  /// Creates the message.
  BacnetOtherNetworkMessage(this.type, List<int> data, {this.vendorId = 0})
    : data = Uint8List.fromList(data) {
    RangeError.checkValueInInterval(type, 0, 255, 'type');
    RangeError.checkValueInInterval(vendorId, 0, 0xFFFF, 'vendorId');
  }

  @override
  final BacnetNetworkMessageType type;

  @override
  final int vendorId;

  /// The octets after the message type (and vendor id).
  final Uint8List data;

  @override
  Uint8List encode() => Uint8List.fromList(data);

  @override
  bool operator ==(Object other) =>
      other is BacnetOtherNetworkMessage &&
      other.type == type &&
      other.vendorId == vendorId &&
      listEquals(other.data, data);

  @override
  int get hashCode => Object.hash(type, vendorId, Object.hashAll(data));

  @override
  String toString() =>
      'BacnetOtherNetworkMessage(${type.label}'
      '${vendorId == 0 ? '' : ', vendor $vendorId'}, ${data.length} octets)';
}

/// A router found by [BacnetNetworkDiscovery.discoverRouters].
@immutable
final class BacnetRouter {
  /// Creates the router.
  BacnetRouter({required List<int> mac, required List<int> networks})
    : mac = Uint8List.fromList(mac),
      networks = List.unmodifiable(networks);

  /// BACnet/IP address of the router (4 bytes IPv4 + 2 bytes port).
  final Uint8List mac;

  /// The networks the router reaches, in ascending order.
  final List<int> networks;

  /// IPv4 address, if BACnet/IP.
  String? get ipAddress =>
      mac.length == 6 ? '${mac[0]}.${mac[1]}.${mac[2]}.${mac[3]}' : null;

  /// UDP port, if BACnet/IP.
  int? get port => mac.length == 6 ? (mac[4] << 8) | mac[5] : null;

  @override
  bool operator ==(Object other) =>
      other is BacnetRouter &&
      listEquals(other.mac, mac) &&
      listEquals(other.networks, networks);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(mac), Object.hashAll(networks));

  @override
  String toString() =>
      'BacnetRouter(${ipAddress != null ? '$ipAddress:$port' : mac}, '
      '${_networks(networks)})';
}
