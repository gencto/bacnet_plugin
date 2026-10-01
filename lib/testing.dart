/// Test doubles for applications using bacnet_plugin.
///
/// [FakeBacnetClient] implements [BacnetClient] with in-memory
/// [FakeBacnetDevice]s, so code using the client, [DeviceScanner] or
/// [PropertyMonitor] can be unit tested without a network or the native
/// stack.
///
/// ```dart
/// import 'package:bacnet_plugin/bacnet_plugin.dart';
/// import 'package:bacnet_plugin/testing.dart';
///
/// final client = FakeBacnetClient(devices: [
///   FakeBacnetDevice(1234)
///     ..addObject(BacnetObjectType.analogInput, 1, presentValue: 21.5),
/// ]);
/// ```
///
/// @docImport 'bacnet_plugin.dart';
/// @docImport 'src/testing/fake_client.dart';
library;

export 'src/testing/fake_client.dart'
    show
        FakeBacnetClient,
        FakeBacnetDevice,
        FakeBacnetObject,
        FakeBacnetRequest;
