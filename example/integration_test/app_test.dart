// Runs on a device/desktop: `flutter test integration_test`.
import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native stack starts and serves objects', (tester) async {
    final server = BacnetServer(
      config: const BacnetConfig(port: 47830, logLevel: BacnetLogLevel.warning),
    );
    final client = BacnetClient(
      config: const BacnetConfig(port: 47830, logLevel: BacnetLogLevel.warning),
    );
    await server.start();
    await client.start();
    try {
      expect(client.nativeVersion, contains('bacnet-stack/'));

      await server.init(4194300, 'IntegrationTest', vendorName: 'example');
      await server.addObject(
        BacnetObjectType.analogValue,
        1,
        name: 'Setpoint',
        units: 62,
        presentValue: 21.5,
      );
      await server.addObject(BacnetObjectType.binaryValue, 1, name: 'Fan');

      expect(
        await server.readProperty(BacnetObjectType.analogValue, 1, 77),
        'Setpoint',
      );
      expect(
        await server.readProperty(BacnetObjectType.analogValue, 1, 85),
        21.5,
      );

      final applied = await server.updatePresentValues(const [
        BacnetPresentValueUpdate(
          objectType: BacnetObjectType.analogValue,
          instance: 1,
          value: 23.0,
        ),
        BacnetPresentValueUpdate(
          objectType: BacnetObjectType.binaryValue,
          instance: 1,
          value: true,
        ),
      ]);
      expect(applied, 2);
      expect(await server.readProperty(BacnetObjectType.binaryValue, 1, 85), 1);

      final stats = await client.stats();
      expect(stats.freeTransactions, greaterThan(0));
    } finally {
      await client.close();
      await server.close();
    }
  });
}
