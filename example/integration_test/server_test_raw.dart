// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Server Discovery via Raw UDP Client', () async {
    // 1. Start Server (BacnetClient -> BacnetServer)
    final server = BacnetServer();
    // Start on port 47808 (default)
    await server.start(port: 47808);
    // Initialize as Device 9999
    await server.init(9999, 'TestServer');

    print('Server started on 47808');

    // 2. Start Raw UDP Socket (Mock Client) on 47809
    final rawSocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      47809,
    );
    print('Raw Client bound to ${rawSocket.address.address}:${rawSocket.port}');

    bool iamReceived = false;

    rawSocket.listen((event) {
      if (event == RawSocketEvent.read) {
        final dgram = rawSocket.receive();
        if (dgram == null) return;

        print('Received bytes: ${dgram.data}');

        // Simple check for IAm APDU
        // BVLC(4) + NPDU(2) + APDU(1) + Service(1)
        // IAm is Unconfirmed(10), Service(00).
        // 81 0a ... 10 00 ...
        if (dgram.data.length > 6 &&
            dgram.data[0] == 0x81 &&
            dgram.data.contains(0x10) && // Unconfirmed Request
            dgram.data.contains(0x00)) {
          // IAm Service
          // This is a very loose check, but sufficient for proof of life
          // Better: check for byte sequence 10 00
          for (int i = 0; i < dgram.data.length - 1; i++) {
            if (dgram.data[i] == 0x10 && dgram.data[i + 1] == 0x00) {
              print('Found IAm Service (10 00)');
              iamReceived = true;
            }
          }
        }
      }
    });

    // 3. Send WhoIs to 47808
    // BVLC: 81 0a 00 08 (Unicast to 47808)
    // NPDU: 01 00 (Ver 1, Normal)
    // APDU: 10 08 (Unconfirmed, WhoIs)
    final whoIs = Uint8List.fromList([
      0x81, 0x0a, 0x00, 0x08, // BVLC
      0x01, 0x00, // NPDU
      0x10, 0x08, // APDU WhoIs
    ]);

    print('Sending WhoIs to 127.0.0.1:47808...');
    rawSocket.send(whoIs, InternetAddress('127.0.0.1'), 47808);

    // Wait for response
    await Future.delayed(const Duration(seconds: 3));

    expect(iamReceived, isTrue, reason: 'Did not receive IAm from server');

    addTearDown(() {
      server.dispose();
      rawSocket.close();
    });
  });
}
