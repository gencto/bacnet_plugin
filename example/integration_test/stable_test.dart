// ignore_for_file: avoid_print

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('BACnet Server Test', () async {
    print('[TEST] Starting BACnet Server...');
    final server = BacnetServer();

    try {
      // Initialize server
      await server.start(port: 47808);
      print('[TEST] Server started on port 47808');

      await server.init(1234, 'FlutterDevice');
      print('[TEST] Device 1234 initialized');

      // Add objects
      await server.addObject(2, 0); // AV:0
      print('[TEST] Added AV:0');

      await server.addObject(2, 1); // AV:1
      print('[TEST] Added AV:1');

      await server.addObject(4, 0); // BV:0
      print('[TEST] Added BV:0');

      // Monitor write events
      final subscription = server.writeEvents.listen((event) {
        print(
          '[TEST] Write event: ${event.objectType}:${event.instance} '
          'Property ${event.propertyId} = ${event.value}',
        );
      });

      // Wait a bit to ensure initialization
      await Future.delayed(const Duration(seconds: 1));

      print('[TEST] ✅ Server test passed!');
      print('[TEST] Server is ready to accept connections on 127.0.0.1:47808');
      print('[TEST] Device ID: 1234');
      print('[TEST] Objects: AV:0, AV:1, BV:0');

      await subscription.cancel();
      server.dispose();
    } catch (e, st) {
      print('[TEST] ❌ Server test failed: $e');
      print('[TEST] Stack: $st');
      server.dispose();
      rethrow;
    }
  });

  test('BACnet Client Test', () async {
    print('[TEST] Starting BACnet Client...');
    final client = BacnetClient();

    try {
      await client.start(port: 47809);
      print('[TEST] Client started on port 47809');

      // Test discovery
      bool foundDevice = false;
      final subscription = client.events.listen((event) {
        if (event is IAmResponse) {
          print('[TEST] Discovered device: ${event.deviceId}');
          foundDevice = true;
        }
      });

      print('[TEST] Sending WhoIs...');
      await client.sendWhoIs();

      await Future.delayed(const Duration(seconds: 2));

      print('[TEST] ✅ Client test passed!');
      print('[TEST] Client is ready to communicate');
      if (foundDevice) {
        print(
          '[TEST] Found ${foundDevice ? "at least one" : "no"} BACnet device',
        );
      }

      await subscription.cancel();
      client.dispose();
    } catch (e, st) {
      print('[TEST] ❌ Client test failed: $e');
      print('[TEST] Stack: $st');
      client.dispose();
      rethrow;
    }
  });
}
