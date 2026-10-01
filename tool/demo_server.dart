// Starts a BACnet server with N analog values and alarm objects; used by
// tests and benchmarks.
// Usage: dart run tool/demo_server.dart [port] [deviceId] [objects]
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bacnet_plugin/bacnet_plugin.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 47811;
  final deviceId = args.length > 1 ? int.parse(args[1]) : 1001;
  final objects = args.length > 2 ? int.parse(args[2]) : 100;
  final iface = Platform.environment['BACNET_IFACE'] ?? 'lo';
  final server = BacnetServer(
    config: BacnetConfig(
      interface: iface,
      port: port,
      logLevel: BacnetLogLevel.warning,
      logger: const ConsoleBacnetLogger(),
    ),
  );
  await server.start();
  await server.init(deviceId, 'DemoServer', vendorName: 'bacnet_plugin');
  for (var i = 0; i < objects; i++) {
    await server.addObject(
      BacnetObjectType.analogValue,
      i,
      name: 'AV-$i',
      units: BacnetEngineeringUnits.degreesCelsius,
      covIncrement: 0.1,
      presentValue: BacnetReal(i.toDouble()),
    );
  }
  await server.addObject(BacnetObjectType.binaryValue, 0, name: 'BV-0');
  await server.addObject(
    BacnetObjectType.multiStateValue,
    0,
    name: 'MSV-0',
    stateTexts: ['Off', 'On', 'Auto'],
    presentValue: const BacnetUnsigned(1),
  );
  // alarms: Notification Class 1 with an analog value that leaves 10..30
  // and a binary value that alarms when active
  await server.addNotificationClass(1, name: 'Alarms');
  await server.addObject(
    BacnetObjectType.analogValue,
    objects,
    name: 'Alarm-AV',
    presentValue: const BacnetReal(20),
  );
  await server.enableEventReporting(
    BacnetObject(type: BacnetObjectType.analogValue, instance: objects),
    notificationClass: 1,
    highLimit: 30,
    lowLimit: 10,
    deadband: 1,
  );
  await server.addObject(BacnetObjectType.binaryValue, 1, name: 'Alarm-BV');
  await server.enableEventReporting(
    const BacnetObject(type: BacnetObjectType.binaryValue, instance: 1),
    notificationClass: 1,
    alarmValue: BacnetBinaryPV.active,
    notifyType: BacnetNotifyType.event,
  );
  server.writeEvents.listen((e) => print('WRITE $e'));
  print('READY ${server.config.port} device $deviceId objects $objects');
  final random = Random(1);
  // keep values moving to exercise COV
  Timer.periodic(const Duration(milliseconds: 200), (_) async {
    await server.updatePresentValues([
      for (var i = 0; i < min(objects, 10); i++)
        BacnetPresentValueUpdate(
          objectType: BacnetObjectType.analogValue,
          instance: i,
          value: BacnetReal(i + random.nextDouble() * 10),
        ),
    ]);
  });
  await ProcessSignal.sigterm.watch().first;
  await server.close();
  exit(0);
}
