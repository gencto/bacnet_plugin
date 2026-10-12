import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/testing.dart';
import 'package:bacnet_plugin_example/app_state.dart';
import 'package:bacnet_plugin_example/screens/object_explorer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('reads all properties and writes the present value', (
    tester,
  ) async {
    final device = FakeBacnetDevice(1234);
    device.addObject(
      BacnetObjectType.analogValue,
      1,
      name: 'Setpoint',
      presentValue: const BacnetReal(21.5),
    );
    final client = FakeBacnetClient(devices: [device]);
    await tester.runAsync(client.start);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(client: client),
        child: const MaterialApp(
          home: ObjectExplorerScreen(
            deviceId: 1234,
            object: BacnetObject(
              type: BacnetObjectType.analogValue,
              instance: 1,
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    // the present value property is read and shown
    expect(find.text('Present Value'), findsOneWidget);
    expect(find.text('21.50'), findsOneWidget);

    // write a new present value
    await tester.tap(find.byTooltip('Write present value'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '25');
    await tester.tap(find.text('Write'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    final write = client.requests.where((r) => r.service == 'writeProperty');
    expect(write, hasLength(1));
    expect(write.first.value, const BacnetReal(25));
    // the reload shows the new value
    expect(find.text('25.00'), findsOneWidget);
  });
}
