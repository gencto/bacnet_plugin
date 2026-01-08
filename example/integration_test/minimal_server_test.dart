// ignore_for_file: avoid_print

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Minimal Server Init Test', () async {
    print('[TEST] Starting server...');
    final server = BacnetServer();

    try {
      await server.start(port: 47808);
      print('[TEST] Server started');

      await server.init(1234, 'TestDevice');
      print('[TEST] Server initialized as Device 1234');

      await server.addObject(2, 0); // Analog Value 0
      print('[TEST] Added AV:0');

      // Success - clean up
      print('[TEST] Test passed!');
      server.dispose();
    } catch (e, st) {
      print('[TEST] ERROR: $e');
      print('[TEST] STACK: $st');
      server.dispose();
      rethrow;
    }
  });
}
