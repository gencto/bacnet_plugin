// Exercises the client against bacnet-stack's reference server (bacserv).
// Usage: dart run tool/interop_client.dart <port> <device>
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';

Future<void> main(List<String> args) async {
  final port = int.parse(args[0]);
  final device = int.parse(args[1]);
  final client = BacnetClient(
    config: const BacnetConfig(
      interface: 'lo',
      port: 47812,
      requestTimeout: Duration(seconds: 10),
      logLevel: BacnetLogLevel.warning,
      logger: ConsoleBacnetLogger(),
    ),
  );
  await client.start();
  await client.addDeviceBinding(device, '127.0.0.1', port: port);
  final scanner = DeviceScanner(client);
  final details = await scanner.getDeviceDetails(device);
  print(
    'details: $details model=${details.modelName} '
    'fw=${details.firmwareRevision} rev=${details.protocolRevision}',
  );
  final objects = await client.scanDevice(device);
  final types = <String, int>{};
  for (final o in objects) {
    final name = BacnetObjectType.getName(o.type);
    types[name] = (types[name] ?? 0) + 1;
  }
  print('objects ${objects.length}: $types');
  final scan = await scanner.scanDevice(
    device,
    propertyIds: const [77, 85, 111],
    maxObjects: 1000,
  );
  final withValues = scan.values.where((p) => p.isNotEmpty).length;
  print('scanned ${scan.length} objects, $withValues with properties');
  final av = objects.firstWhere((o) => o.type == BacnetObjectType.analogValue);
  print(
    'AV ${av.instance} = ${await client.readProperty(device, av.type, av.instance, 85)}',
  );
  await client.writeProperty(
    device,
    av.type,
    av.instance,
    85,
    33.25,
    priority: 9,
  );
  print(
    'AV after write = ${await client.readProperty(device, av.type, av.instance, 85)}',
  );
  await client.writeProperty(
    device,
    av.type,
    av.instance,
    85,
    null,
    priority: 9,
  );
  print(
    'AV after relinquish = ${await client.readProperty(device, av.type, av.instance, 85)}',
  );
  print(
    'local date/time: ${await client.readProperty(device, 8, device, 56)} '
    '${await client.readProperty(device, 8, device, 57)}',
  );
  final tl = objects.where((o) => o.type == BacnetObjectType.trendLog).toList();
  if (tl.isNotEmpty) {
    try {
      final log = await client.getTrendLog(device, tl.first.instance, count: 5);
      print(
        'trend log ${tl.first.instance}: $log ${log.entries.take(3).toList()}',
      );
    } on BacnetException catch (e) {
      print('trend log failed: $e');
    }
  }
  final covs = <CovNotificationEvent>[];
  final sub = client.covEvents.listen(covs.add);
  await client.subscribeCOV(
    device,
    av.type,
    av.instance,
    processId: 3,
    lifetime: const Duration(seconds: 30),
  );
  await client.writeProperty(
    device,
    av.type,
    av.instance,
    85,
    50.0,
    priority: 9,
  );
  await Future<void>.delayed(const Duration(seconds: 2));
  print('cov: ${covs.length} ${covs.isEmpty ? '' : covs.last}');
  await client.unsubscribeCOV(device, av.type, av.instance, processId: 3);
  await sub.cancel();
  await client.writeProperty(
    device,
    av.type,
    av.instance,
    85,
    null,
    priority: 9,
  );
  try {
    await client.readProperty(device, 2, 4000000, 85);
  } on BacnetProtocolException catch (e) {
    print('expected: $e');
  }
  try {
    await client.readProperty(
      4000001,
      2,
      1,
      85,
      timeout: const Duration(seconds: 3),
    );
  } on BacnetException catch (e) {
    print('expected: $e');
  }
  final sw = Stopwatch()..start();
  await Future.wait([
    for (var i = 0; i < 1000; i++)
      client.readProperty(device, av.type, av.instance, 85),
  ]);
  print('1000 reads against bacserv: ${sw.elapsedMilliseconds} ms');
  print(await client.stats());
  await client.close();
  exit(0);
}
