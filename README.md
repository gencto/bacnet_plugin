# BACnet Plugin

[![pub package](https://img.shields.io/pub/v/bacnet_plugin.svg)](https://pub.dev/packages/bacnet_plugin)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

A Flutter FFI plugin for BACnet protocol communication, supporting both client and server operations with an isolate-based architecture for optimal performance.

## Features

✅ **BACnet Client** - Read and write properties, discover devices, subscribe to COV  
✅ **BACnet Server** - Host BACnet objects and respond to client requests  
✅ **Cross-Platform** - Windows, Linux, macOS, Android, iOS  
✅ **Non-Blocking** - Isolate-based architecture prevents UI freezing  
✅ **Type-Safe** - Named constants for all BACnet protocol values  
✅ **Modern Logging** - DevTools integration with structured logging  
✅ **JSON Serialization** - Easy API integration with JSON support  
✅ **Fully Documented** - Comprehensive dartdoc for all public APIs

## Installation

Add this to your `pubspec.yaml`:

```yaml
dependencies:
  bacnet_plugin: ^0.0.1
```

Then run:

```bash
flutter pub get
```

## Quick Start

### BACnet Client

```dart
import 'package:bacnet_plugin/bacnet_plugin.dart';

void main() async {
  // Create client with DevTools logging
  final client = BacnetClient(
    logger: DeveloperBacnetLogger(name: 'my_app.bacnet'),
  );

  // Start the BACnet stack
  await client.start(interface: '192.168.1.100');

  // Discover devices on the network
  await client.sendWhoIs();

  // Listen for I-Am responses
  client.events.listen((event) {
    if (event is IAmResponse) {
      print('Found device: ${event.deviceId}');
    }
  });

  // Read a property
  final temperature = await client.readProperty(
    1234,                              // Device ID
    BacnetObjectType.analogInput,      // Object type
    1,                                 // Instance
    BacnetPropertyId.presentValue,     // Property ID
  );
  print('Temperature: $temperature°C');

  // Write a property
  await client.writeProperty(
    1234,
    BacnetObjectType.analogOutput,
    1,
    BacnetPropertyId.presentValue,
    75.5,                              // Value
    priority: 8,                       // Write priority
  );

  // Clean up
  client.dispose();
}
```

### BACnet Server

```dart
import 'package:bacnet_plugin/bacnet_plugin.dart';

void main() async {
  final server = BacnetServer(
    logger: DeveloperBacnetLogger(),
  );

  // Start the server
  await server.start(interface: '192.168.1.100');

  // Initialize as a BACnet device
  await server.init(
    deviceId: 4194304,
    deviceName: 'Flutter BACnet Server',
  );

  // Add objects to serve
  await server.addObject(BacnetObjectType.analogInput, 1);
  await server.addObject(BacnetObjectType.binaryValue, 1);

  // Listen for write requests
  server.writeEvents.listen((event) {
    print('Property written: ${event.objectType}:${event.instance}');
    print('Value: ${event.value}');
  });
}
```

## Core Concepts

### BACnet Constants

The plugin provides named constants for all BACnet protocol values:

```dart
// Object Types
BacnetObjectType.analogInput        // 0
BacnetObjectType.analogOutput       // 1
BacnetObjectType.device             // 8
BacnetObjectType.trendLog           // 20

// Property IDs
BacnetPropertyId.objectName         // 77
BacnetPropertyId.presentValue       // 85
BacnetPropertyId.description        // 28
BacnetPropertyId.units              // 117

// Error Codes
BacnetErrorClass.device             // Device errors
BacnetErrorCode.timeout             // Timeout error
BacnetErrorCode.unknownObject       // Object not found
```

See the full list in:

- [BacnetObjectType](lib/src/constants/object_types.dart)
- [BacnetPropertyId](lib/src/constants/property_ids.dart)
- [BacnetErrorClass/Code](lib/src/constants/error_codes.dart)

### Logging Options

Choose the logger that fits your needs:

```dart
// For production - integrates with Dart DevTools
final client = BacnetClient(
  logger: DeveloperBacnetLogger(name: 'my_app'),
);

// For simple console output
final client = BacnetClient(
  logger: ConsoleBacnetLogger(),
);

// Custom logger
class MyLogger implements BacnetLogger {
  @override
  void log(BacnetLogLevel level, String message, [Object? error, StackTrace? stackTrace]) {
    // Your custom logging logic
  }
}
```

### Data Models

All models support JSON serialization:

```dart
// Create an object
final sensor = BacnetObject(
  type: BacnetObjectType.analogInput,
  instance: 1,
  properties: {
    BacnetPropertyId.objectName: 'Temperature Sensor',
    BacnetPropertyId.presentValue: 22.5,
    BacnetPropertyId.units: 62,  // Celsius
  },
);

// Serialize to JSON
final json = sensor.toJson();

// Deserialize from JSON
final restored = BacnetObject.fromJson(json);

// Immutable updates with copyWith
final updated = sensor.copyWith(
  properties: {
    ...sensor.properties,
    BacnetPropertyId.presentValue: 23.0,
  },
);

// Helper getters
print(sensor.name);              // 'Temperature Sensor'
print(sensor.presentValue);      // 22.5
print(sensor.description);       // null if not set
```

## Advanced Usage

### Read Property Multiple (RPM)

Efficiently read multiple properties in one request:

```dart
final specs = [
  BacnetReadAccessSpecification(
    objectIdentifier: BacnetObject(
      type: BacnetObjectType.analogInput,
      instance: 1,
    ),
    properties: [
      BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.presentValue),
      BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.objectName),
      BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.units),
    ],
  ),
];

final results = await client.readMultiple(1234, specs);
```

### Write Property Multiple (WPM)

Write multiple properties in one request:

```dart
final specs = [
  BacnetWriteAccessSpecification(
    objectIdentifier: BacnetObject(
      type: BacnetObjectType.analogOutput,
      instance: 1,
    ),
    listOfProperties: [
      BacnetPropertyValue(
        propertyIdentifier: BacnetPropertyId.presentValue,
        value: 75.5,
        priority: 8,
      ),
    ],
  ),
];

await client.writeMultiple(1234, specs);
```

### Change of Value (COV) Subscriptions

Get notified when a property value changes:

```dart
// Subscribe to COV notifications
await client.subscribeCOV(
  1234,                              // Device ID
  BacnetObjectType.analogInput,      // Object type
  1,                                 // Instance
  propId: BacnetPropertyId.presentValue,
);

// Listen for COV notifications
client.events.listen((event) {
  if (event is COVNotification) {
    print('Value changed: ${event.value}');
  }
});
```

### High-Level Property Monitoring

Simplify monitoring with automatic COV subscription and polling fallback:

```dart
final monitor = PropertyMonitor(client);

// Monitor a property
monitor.monitor(
  deviceId: 1234,
  object: BacnetObject(type: BacnetObjectType.analogInput, instance: 1),
  propertyId: BacnetPropertyId.presentValue,
).listen((update) {
  print('Value: ${update.value} (from ${update.source.name})');
});
```

### Foreign Device Registration

Communicate across network boundaries:

```dart
// Register with BBMD (BACnet Broadcast Management Device)
await client.registerForeignDevice(
  '192.168.1.1',  // BBMD IP
  port: 47808,
  ttl: 120,       // Time-to-live in seconds
);
```

### Device Discovery and Scanning

```dart
// Discover all devices
await client.sendWhoIs();

// Discover devices in a range
await client.sendWhoIs(lowLimit: 1000, highLimit: 2000);

// Scan a device for objects
final objects = await client.scanDevice(1234);
for (final obj in objects) {
  print('Found: ${BacnetObjectType.getName(obj.type)} #${obj.instance}');
}
```

## Architecture

The plugin uses an **isolate-based architecture** to prevent blocking the UI thread:

```
┌─────────────────┐
│   Flutter UI    │
└────────┬────────┘
         │
    ┌───▼────┐
    │ Client │  (Main Isolate)
    │ Server │
    └───┬────┘
        │
   ┌────▼─────────┐
   │ BacnetSystem │  (Manages Worker)
   └────┬─────────┘
        │
   ┌────▼──────────┐
   │ Worker Isolate│  (Native BACnet Stack)
   └───────────────┘
```

All native BACnet operations run in a separate isolate, ensuring:

- ✅ Non-blocking network I/O
- ✅ Smooth UI performance
- ✅ Background processing
- ✅ Efficient resource usage

## Supported BACnet Services

### Client Services

- ✅ Who-Is / I-Am
- ✅ Read-Property
- ✅ Read-Property-Multiple
- ✅ Write-Property
- ✅ Write-Property-Multiple
- ✅ Subscribe-COV
- ✅ Register Foreign Device
- ✅ Device and Object Discovery

### Server Services

- ✅ I-Am Response
- ✅ Read-Property Response
- ✅ Write-Property Handling
- ✅ Object Hosting

## Supported Platforms

| Platform | Supported | Tested |
| -------- | --------- | ------ |
| Windows  | ✅        | ✅     |
| Linux    | ✅        | ✅     |
| macOS    | ✅        | ⚠️     |
| Android  | ✅        | ⚠️     |
| iOS      | ✅        | ⚠️     |

Legend: ✅ Fully supported | ⚠️ Supported but not extensively tested

## Error Handling

```dart
try {
  final value = await client.readProperty(
    1234,
    BacnetObjectType.analogInput,
    1,
    BacnetPropertyId.presentValue,
  );
} on BacnetTimeoutException catch (e) {
  print('Request timed out: $e');
} on BacnetProtocolException catch (e) {
  print('Protocol error: ${e.errorClass}:${e.errorCode}');
} on BacnetException catch (e) {
  print('BACnet error: $e');
}
```

## Configuration

```dart
final config = BacnetConfig(
  interface: '192.168.1.100',        // Local interface
  port: 47808,                       // BACnet/IP port
  requestTimeout: Duration(seconds: 10),
  maxRetries: 3,
  logger: DeveloperBacnetLogger(),
);

// Note: Config class available for future use
// Current API uses individual parameters
```

## Examples

Check out the [example](example/) directory for complete working examples:

- **Client Example** - Basic client operations
- **Server Example** - Hosting BACnet objects
- **Advanced Usage** - RPM, WPM, COV subscriptions

Run the example:

```bash
cd example
flutter run
```

## Testing

The plugin includes integration tests:

```bash
# Run integration tests
cd example
flutter test integration_test/
```

## Contributing

Contributions are welcome! Please read our [Contributing Guide](CONTRIBUTING.md) first.

### Development Setup

1. Clone the repository
2. Install dependencies: `flutter pub get`
3. Run code generation: `dart run build_runner build`
4. Run tests: `flutter test`
5. Check analysis: `flutter analyze`

## BACnet Protocol Information

BACnet (Building Automation and Control Networks) is an ASHRAE, ANSI, and ISO standard protocol for building automation and control systems.

**Resources:**

- [BACnet International](https://bacnetinternational.org/)
- [ASHRAE Standard 135](https://www.ashrae.org/technical-resources/bookstore/bacnet)
- [Wikipedia: BACnet](https://en.wikipedia.org/wiki/BACnet)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Support

- 📫 Issues: [GitHub Issues](https://github.com/gencto/bacnet_plugin/issues)
- 📖 Documentation: [API Reference](https://pub.dev/documentation/bacnet_plugin/latest/)
- 💬 Discussions: [GitHub Discussions](https://github.com/gencto/bacnet_plugin/discussions)

## Acknowledgments

Built with Flutter FFI and powered by the BACnet Stack library.

---

**Made with ❤️ for the Flutter and BACnet communities**
