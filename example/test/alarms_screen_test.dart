import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/testing.dart';
import 'package:bacnet_plugin_example/app_state.dart';
import 'package:bacnet_plugin_example/screens/alarms_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('lists, receives and acknowledges alarms', (tester) async {
    final device = FakeBacnetDevice(1234)..addNotificationClass(1);
    final sensor = device.addObject(
      BacnetObjectType.analogInput,
      1,
      name: 'Room',
    )..enableEventReporting(notificationClass: 1);
    final client = FakeBacnetClient(devices: [device]);

    await tester.runAsync(() async {
      await client.start();
      sensor.reportEvent(
        BacnetEventState.highLimit,
        eventValues: const BacnetOutOfRangeValues(
          exceedingValue: 31,
          statusFlags: BacnetStatusFlags(inAlarm: true),
          deadband: 1,
          exceededLimit: 30,
        ),
      );
    });
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(client: client),
        child: const MaterialApp(
          home: AlarmsScreen(deviceId: 1234, notificationClasses: [1]),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(find.text('Active (1)'), findsOneWidget);
    expect(find.text('High Limit · Alarm'), findsOneWidget);
    expect(
      client.requests.where((r) => r.service == 'addListElement'),
      hasLength(1),
    );

    // a notification arrives while the screen is open
    await tester.runAsync(() async {
      sensor.reportEvent(BacnetEventState.normal);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('High Limit → Normal'), findsOneWidget);

    await tester.tap(find.text('Acknowledge'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(
      client.requests
          .where((r) => r.service == 'acknowledgeAlarm')
          .single
          .source,
      'BACnet Demo',
    );
    expect(find.text('Active (0)'), findsOneWidget);

    // leaving the screen cancels the subscription
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      client.requests.where((r) => r.service == 'removeListElement'),
      hasLength(1),
    );
  });
}
