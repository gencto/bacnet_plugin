// ignore_for_file: avoid_print
import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Basic smoke test to verify Native Bindings (Client & Server) don't crash
  testWidgets('Core Native Stack Smoke Test', (WidgetTester tester) async {
    final server = BacnetServer();
    final client = BacnetClient(); // Uses same singleton instance

    try {
      // 1. Startup
      await server.start();
      print('Core: Native Stack started');

      // 2. Server Initialization
      await server.init(123456, 'FlutterTestDevice');
      print('Core: Server initialized as Device 123456');

      await server.addObject(BacnetObjectType.analogValue, 1);
      print('Core: Added AnalogValue:1');

      // 3. WhoIs (Broadcast)
      await client.sendWhoIs();
      print('Core: WhoIs sent');

      // Allow some time for async processing
      await Future<void>.delayed(const Duration(seconds: 2));

      // 4. ReadProperty (Self-Read attempt)
      // Note: Some stacks do not support local loopback. We expect Success OR Timeout, but NO CRASH.
      try {
        await client
            .readProperty(
              123456,
              BacnetObjectType.analogValue,
              1,
              BacnetPropertyId.presentValue,
            )
            .timeout(const Duration(seconds: 2));
        print('Core: Self-Read successful (Loopback supported)');
      } on BacnetTimeoutException {
        print('Core: Self-Read timed out (Loopback not supported/configured)');
      } on Exception catch (e) {
        print('Core: Self-Read threw safe exception: $e');
      }

      // 5. WritePropertyMultiple (Self-Write attempt)
      try {
        await client
            .writeMultiple(123456, [
              const BacnetWriteAccessSpecification(
                objectIdentifier: BacnetObject(
                  type: BacnetObjectType.analogValue,
                  instance: 1,
                ),
                listOfProperties: [
                  BacnetPropertyValue(
                    propertyIdentifier: BacnetPropertyId.presentValue,
                    value: 75.0,
                  ),
                ],
              ),
            ])
            .timeout(const Duration(seconds: 2));
        print('Core: Self-Write successful/attempted');
      } on Exception catch (e) {
        print('Core: Self-Write timeout/error handled: $e');
      }
    } finally {
      client.dispose();
      print('Core: Stack disposed');
    }
  });
}
