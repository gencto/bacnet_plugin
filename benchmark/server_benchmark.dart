// Server benchmark: creates many objects and measures how fast present
// values are pushed into the native stack.
//   dart run benchmark/server_benchmark.dart [objects] [interface]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';

Future<void> main(List<String> args) async {
  final count = args.isNotEmpty ? int.parse(args[0]) : 10000;
  final server = BacnetServer(
    config: BacnetConfig(
      interface: args.length > 1 ? args[1] : 'lo',
      port: 47898,
      logLevel: BacnetLogLevel.warning,
      logger: const ConsoleBacnetLogger(),
    ),
  );
  await server.start();
  await server.init(4000, 'Benchmark');
  var clock = Stopwatch()..start();
  await Future.wait([
    for (var i = 0; i < count; i++)
      server.addObject(BacnetObjectType.analogValue, i, name: 'AV-$i'),
  ]);
  print('created $count objects in ${clock.elapsedMilliseconds} ms');

  for (var round = 0; round < 3; round++) {
    clock = Stopwatch()..start();
    final applied = await server.updatePresentValues([
      for (var i = 0; i < count; i++)
        BacnetPresentValueUpdate(
          objectType: BacnetObjectType.analogValue,
          instance: i,
          value: i * 0.5 + round,
        ),
    ]);
    final ms = clock.elapsedMicroseconds / 1000;
    print(
      'batch update: $applied values in ${ms.toStringAsFixed(1)} ms '
      '(${(applied / ms * 1000).toStringAsFixed(0)} values/s)',
    );
  }

  clock = Stopwatch()..start();
  await Future.wait([
    for (var i = 0; i < 2000; i++)
      server.setPresentValue(
        BacnetObjectType.analogValue,
        i % count,
        i.toDouble(),
      ),
  ]);
  print('2000 single updates in ${clock.elapsedMilliseconds} ms');
  final value = await server.readProperty(BacnetObjectType.analogValue, 1, 85);
  print('AV-1 present value: $value');
  await server.close();
  exit(0);
}
