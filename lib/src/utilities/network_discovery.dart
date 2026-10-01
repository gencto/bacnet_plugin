import 'dart:async';

import '../client/bacnet_client.dart';
import '../core/exceptions.dart';
import '../core/ip_address.dart';
import '../models/events.dart';
import '../models/network.dart';

/// Discovery of routers and networks with network layer messages.
///
/// ```dart
/// for (final router in await client.discoverRouters()) {
///   print('${router.ipAddress}:${router.port} -> ${router.networks}');
/// }
/// print('local network: ${(await client.whatIsNetworkNumber())?.network}');
/// ```
extension BacnetNetworkDiscovery on BacnetClient {
  /// Broadcasts a Who-Is-Router-To-Network: the routers to [network], or
  /// all routers when it is null, answer with I-Am-Router-To-Network
  /// ([BacnetClient.networkMessages]).
  Future<void> whoIsRouterToNetwork({int? network}) =>
      sendNetworkMessage(BacnetWhoIsRouterToNetwork(network: network));

  /// Finds the routers of the local network (and of the networks a BBMD
  /// connects): broadcasts Who-Is-Router-To-Network and collects the
  /// I-Am-Router-To-Network answers for [timeout].
  ///
  /// With [network] only the routers to that network answer.
  Future<List<BacnetRouter>> discoverRouters({
    int? network,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final found = <String, ({List<int> mac, Set<int> networks})>{};
    final subscription = networkMessages.listen((event) {
      if (event.message case BacnetIAmRouterToNetwork(:final networks)) {
        final router = found[event.mac.join('.')] ??= (
          mac: event.mac,
          networks: <int>{},
        );
        router.networks.addAll(networks);
      }
    });
    try {
      await whoIsRouterToNetwork(network: network);
      await Future<void>.delayed(timeout);
    } finally {
      await subscription.cancel();
    }
    return [
      for (final router in found.values)
        BacnetRouter(
          mac: router.mac,
          networks: router.networks.toList()..sort(),
        ),
    ];
  }

  /// Asks for the number of the local network (What-Is-Network-Number):
  /// the first Network-Number-Is answer, or null when no device knows the
  /// number within [timeout].
  Future<BacnetNetworkNumberIs?> whatIsNetworkNumber({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final answer = await _networkAnswer(
      // sent with a local broadcast, never routed
      (event) => event.net == 0 && event.message is BacnetNetworkNumberIs,
      timeout,
      () => sendNetworkMessage(const BacnetWhatIsNetworkNumber()),
    );
    return answer?.message as BacnetNetworkNumberIs?;
  }

  /// Reads the routing table of the router at [ip] (an IPv4 address or
  /// host name) and [port]: sends an Initialize-Routing-Table without
  /// entries, which routers answer with their table.
  ///
  /// Throws a [BacnetTimeoutException] when the router does not answer
  /// within [timeout], and a [BacnetException] when it rejects the query.
  Future<List<BacnetRoutingTableEntry>> readRoutingTable(
    String ip, {
    int port = 47808,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final mac = await resolveBacnetIp(ip, port);
    bool fromRouter(NetworkMessageEvent event) {
      if (event.net != 0 || event.mac.length != mac.length) return false;
      for (var i = 0; i < mac.length; i++) {
        if (event.mac[i] != mac[i]) return false;
      }
      return true;
    }

    final answer = await _networkAnswer(
      (event) =>
          fromRouter(event) &&
          (event.message is BacnetInitializeRoutingTableAck ||
              event.message is BacnetRejectMessageToNetwork),
      timeout,
      () => sendNetworkMessage(
        BacnetInitializeRoutingTable(),
        ip: ip,
        port: port,
      ),
    );
    return switch (answer?.message) {
      BacnetInitializeRoutingTableAck(:final entries) => entries,
      BacnetRejectMessageToNetwork(:final reason) => throw BacnetException(
        'router $ip:$port rejected the routing table query: ${reason.label}',
      ),
      _ => throw BacnetTimeoutException('router $ip:$port did not answer'),
    };
  }

  /// Sends a message with [send] and waits up to [timeout] for the first
  /// network message that passes [test].
  Future<NetworkMessageEvent?> _networkAnswer(
    bool Function(NetworkMessageEvent event) test,
    Duration timeout,
    Future<void> Function() send,
  ) async {
    final answer = Completer<NetworkMessageEvent?>();
    final subscription = networkMessages.listen((event) {
      if (!answer.isCompleted && test(event)) answer.complete(event);
    });
    final timer = Timer(timeout, () {
      if (!answer.isCompleted) answer.complete(null);
    });
    try {
      await send();
      return await answer.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }
}
