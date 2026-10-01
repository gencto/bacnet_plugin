# bacnet_plugin examples

## Dart

A headless gateway that discovers devices, reads values and hosts its own
BACnet device:

```dart
import 'package:bacnet_plugin/bacnet_plugin.dart';

Future<void> main() async {
  // Client and server share the process wide BACnet stack.
  final client = BacnetClient(
    config: const BacnetConfig(interface: '192.168.1.100'),
  );
  final server = BacnetServer();
  await client.start();
  await server.start();

  // Discovery
  client.iAmEvents.listen((iAm) {
    print('device ${iAm.deviceId} at ${iAm.ipAddress}:${iAm.port}');
  });
  await client.sendWhoIs();

  // Reads (unknown devices are bound automatically with a targeted Who-Is)
  final temperature = await client.readProperty(
    1234,
    BacnetObjectType.analogInput,
    1,
    BacnetPropertyId.presentValue,
  );
  final values = await client.readMultiple(1234, [
    const BacnetReadAccessSpecification(
      objectIdentifier: BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
      ),
      properties: [
        BacnetPropertyReference(
          propertyIdentifier: BacnetPropertyId.objectName,
        ),
        BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.units),
      ],
    ),
  ]);
  print('temperature: $temperature, $values');

  // Server: expose the value to other BACnet clients
  await server.init(4194300, 'Gateway', vendorName: 'ACME');
  await server.addObject(
    BacnetObjectType.analogValue,
    1,
    name: 'Mirrored Temperature',
    units: BacnetEngineeringUnits.degreesCelsius,
    presentValue: (temperature as num).toDouble(),
  );
  server.writeEvents.listen((write) {
    print('${write.objectType}:${write.instance} <- ${write.value}');
  });

  // Change of value notifications instead of polling
  final monitor = PropertyMonitor(client);
  monitor
      .monitorPresentValue(
        1234,
        const BacnetObject(type: BacnetObjectType.analogInput, instance: 1),
      )
      .listen(
        (update) => server.setPresentValue(
          BacnetObjectType.analogValue,
          1,
          update.value,
        ),
      );
}
```

More complete programs:

- [`tool/demo_server.dart`](https://github.com/gencto/bacnet_plugin/blob/main/tool/demo_server.dart):
  a server with many objects, used by the integration tests;
- [`benchmark/load_test.dart`](https://github.com/gencto/bacnet_plugin/blob/main/benchmark/load_test.dart):
  concurrent ReadProperty/ReadPropertyMultiple load generator.

## Flutter

This directory is a Flutter app (Android, iOS, Linux, macOS, Windows) with
device discovery, an object browser, COV monitoring and a server mode with
editable objects.

```sh
cd example
flutter run
```

The integration test runs the app against a server in the same process:

```sh
flutter test integration_test/app_test.dart
```
