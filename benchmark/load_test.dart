// Client load test: issues many concurrent requests against one or more
// devices and reports throughput and latency. The mode selects the service:
// `rp` ReadProperty (the default), `rpm` ReadPropertyMultiple, `write`
// WriteProperty of a present value. Concurrent ReadProperty calls are merged
// into ReadPropertyMultiple unless `--coalesce false` is given.
//
// Start servers first (e.g. `dart run tool/demo_server.dart 47811 1001 100`)
// then run:
//   dart run benchmark/load_test.dart --targets 127.0.0.1:47811:1001 \
//       --requests 20000 --interface lo
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';

Future<void> main(List<String> args) async {
  final options = _parse(args);
  final targets = options['targets']!.split(',').map((t) {
    final parts = t.split(':');
    return (
      host: parts[0],
      port: int.parse(parts[1]),
      device: int.parse(parts[2]),
    );
  }).toList();
  final total = int.parse(options['requests'] ?? '10000');
  final mode = options['mode'] ?? 'rp';
  final objects = int.parse(options['objects'] ?? '100');
  final client = BacnetClient(
    config: BacnetConfig(
      interface: options['interface'],
      port: int.parse(options['port'] ?? '47899'),
      maxConcurrentRequests: int.parse(options['concurrency'] ?? '200'),
      maxConcurrentRequestsPerDevice: int.parse(options['per-device'] ?? '8'),
      maxQueuedRequests: total + 1000,
      coalesceReads: options['coalesce'] != 'false',
      logLevel: BacnetLogLevel.warning,
      logger: const ConsoleBacnetLogger(),
    ),
  );
  await client.start();
  for (final t in targets) {
    await client.addDeviceBinding(t.device, t.host, port: t.port);
  }
  print('engine: ${client.nativeVersion}');
  print('targets: ${targets.length}, requests: $total, mode: $mode');

  final latencies = <int>[];
  var errors = 0;
  final clock = Stopwatch()..start();
  // Callbacks instead of one async closure per request: in JIT mode
  // (`dart run`) tens of thousands of suspended async calls are expensive
  // to deoptimize and would measure the VM instead of the client.
  Future<void> request(int i) {
    final target = targets[i % targets.length];
    final started = clock.elapsedMicroseconds;
    final Future<Object> response = switch (mode) {
      'rpm' => client.readMultiple(target.device, [
        for (var o = 0; o < 10; o++)
          BacnetReadAccessSpecification(
            objectIdentifier: BacnetObject(
              type: BacnetObjectType.analogValue,
              instance: (i + o) % objects,
            ),
            properties: const [
              BacnetPropertyReference(
                propertyIdentifier: BacnetPropertyId.presentValue,
              ),
              BacnetPropertyReference(
                propertyIdentifier: BacnetPropertyId.statusFlags,
              ),
            ],
          ),
      ]),
      'write' =>
        client
            .write(
              target.device,
              BacnetObject(
                type: BacnetObjectType.analogValue,
                instance: i % objects,
              ),
              BacnetProperties.analogPresentValue,
              (i % 100).toDouble(),
            )
            .then<Object>((_) => true),
      _ => client.readProperty(
        target.device,
        BacnetObjectType.analogValue,
        i % objects,
        BacnetPropertyId.presentValue,
      ),
    };
    return response
        .then((_) => latencies.add(clock.elapsedMicroseconds - started))
        .catchError((Object _) {
          errors++;
        }, test: (error) => error is BacnetException);
  }

  await Future.wait([for (var i = 0; i < total; i++) request(i)]);
  final seconds = clock.elapsedMicroseconds / 1e6;
  latencies.sort();
  String pct(double p) => latencies.isEmpty
      ? '-'
      : '${(latencies[((latencies.length - 1) * p).round()] / 1000).toStringAsFixed(1)} ms';
  final values = mode == 'rpm' ? 20 : 1;
  print(
    'completed: ${latencies.length}, errors: $errors, '
    'time: ${seconds.toStringAsFixed(2)} s',
  );
  print(
    'throughput: ${(latencies.length / seconds).toStringAsFixed(0)} req/s, '
    '${(latencies.length * values / seconds).toStringAsFixed(0)} values/s',
  );
  print('latency p50: ${pct(0.5)}, p99: ${pct(0.99)}, max: ${pct(1)}');
  print(await client.stats());
  await client.close();
  exit(errors == 0 ? 0 : 1);
}

Map<String, String> _parse(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    result[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  if (!result.containsKey('targets')) {
    stderr.writeln(
      'usage: load_test.dart --targets host:port:device[,...] '
      '[--requests N] [--mode rp|rpm|write] [--interface lo] '
      '[--concurrency 200] [--per-device 8] [--objects 100] '
      '[--coalesce true|false]',
    );
    exit(64);
  }
  return result;
}
