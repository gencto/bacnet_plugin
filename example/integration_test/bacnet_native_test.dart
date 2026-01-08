import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Test Native BACnet Functionality', (WidgetTester tester) async {
    // 1. Initialize Client
    final client = BacnetClient();
    bool initSuccess = false;

    try {
      // 2. Start Client (Spins up worker isolate & native stack)
      await client.start();
      initSuccess = true;

      // Allow some time for the worker to initialize
      await Future.delayed(const Duration(seconds: 1));

      // 3. Test Add Device Binding
      // Triggers: bip_get_addr_by_name, address_add
      await client.addDeviceBinding(1234, '192.168.1.100', port: 47808);

      // 4. Test Register Foreign Device
      // Triggers: bvlc_address_from_ascii, bvlc_register_with_bbmd
      await client.registerForeignDevice('192.168.1.1', port: 47808, ttl: 60);

      // 5. Test Subscribe COV
      // Triggers: Send_COV_Subscribe
      // We don't expect a real response, just that the native call works
      await client.subscribeCOV(
        1234,
        0,
        1,
      ); // Device 1234, Analog Input (0), Instance 1

      // 6. Test Write Property
      // Triggers: Send_Write_Property_Request
      await client.writeProperty(
        1234,
        0, // Analog Input
        1, // Instance
        85, // Present Value
        100.0, // Value
        tag: 4, // Real
      );

      // 7. Test Read Property (Expect Timeout)
      // Triggers: Send_Read_Property_Request
      try {
        await client.readProperty(
          1234,
          0, // Analog Input
          1, // Instance
          85, // Present Value
        );
      } catch (e) {
        // Expected timeout as there is no real device
        expect(e.toString(), contains('ReadProperty timed out'));
      }

      // 8. Test WhoIs
      // Triggers: Send_WhoIs_Global
      await client.sendWhoIs();

      // If we got here without crashing, the native bindings are working
    } catch (e, st) {
      fail('Test failed with exception: $e\n$st');
    } finally {
      client.dispose();
    }

    expect(initSuccess, isTrue);
  });
}
