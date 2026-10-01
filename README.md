# BACnet Plugin

[![pub package](https://img.shields.io/pub/v/bacnet_plugin.svg)](https://pub.dev/packages/bacnet_plugin)
[![CI](https://github.com/gencto/bacnet_plugin/actions/workflows/ci.yml/badge.svg)](https://github.com/gencto/bacnet_plugin/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

High-throughput BACnet/IP **client and server** for Dart and Flutter, built
on [bacnet-stack](https://github.com/bacnet-stack/bacnet-stack) 1.6.1 through
FFI. Works in Flutter apps (Android, iOS, Linux, macOS, Windows) and in plain
Dart programs such as headless gateways and supervisory services.

## Features

- **Client**: Who-Is/I-Am discovery, ReadProperty, ReadPropertyMultiple
  (split automatically when the answer exceeds the device's APDU),
  WriteProperty(Multiple) with datatype inference, SubscribeCOV(Property)
  with decoded notifications, ReadRange/Trend Logs, time synchronization,
  foreign device registration and raw confirmed services.
- **Server**: hosts Analog/Binary/Multi-state Input/Output/Value, Integer,
  Positive Integer and CharacterString Value objects; answers Who-Is,
  Read/WriteProperty(Multiple), SubscribeCOV(Property), ReadRange,
  DeviceCommunicationControl and ReinitializeDevice natively; batch updates
  of present values; write notifications.
- **Built for load**: request scheduler with global and per-device
  concurrency limits, back pressure, automatic address binding, batched
  isolate messaging and zero-copy event processing.
- **Robust**: bounds-checked decoder (fuzz tested), typed exceptions,
  protection against late replies with recycled invoke ids, no
  `exit()`/`longjmp` tricks in native code.
- **Modern build**: native code is compiled by a
  [build hook](https://dart.dev/tools/hooks) for every platform — no CMake,
  Gradle or CocoaPods configuration in the package.

## Installation

```yaml
dependencies:
  bacnet_plugin: ^0.1.0
```

Requirements:

- Dart 3.11+ / Flutter 3.44+ (build hooks).
- A C compiler on the build machine: Xcode (macOS/iOS), Visual Studio with
  the C++ workload (Windows), clang or gcc (Linux), the Android NDK
  installed by Flutter (Android).
- Git dependencies must be fetched with submodules
  (`native/bacnet-stack` is pinned to a bacnet-stack release); the pub.dev
  package already contains the sources.

Platform notes:

- **Android**: add `android.permission.INTERNET` to the app manifest. Some
  devices drop broadcast packets in power saving mode; acquire a
  `WifiManager.MulticastLock` if discovery is unreliable.
- **iOS 14+**: add `NSLocalNetworkUsageDescription` to `Info.plist`.
- **macOS**: enable `com.apple.security.network.client` and
  `com.apple.security.network.server` entitlements.
- **Interface**: pass an interface name (`eth0`, `en0`) or an IPv4
  address. On Windows only IPv4 addresses are accepted.

## Quick start

### Client

```dart
import 'package:bacnet_plugin/bacnet_plugin.dart';

Future<void> main() async {
  final client = BacnetClient(
    config: const BacnetConfig(interface: '192.168.1.100'),
  );
  await client.start();

  client.iAmStream.listen((iAm) {
    print('device ${iAm.deviceId} at ${iAm.ipAddress}:${iAm.port}');
  });
  await client.sendWhoIs();

  // Unknown devices are bound automatically with a targeted Who-Is.
  final temperature = await client.readProperty(
    1234,
    BacnetObjectType.analogInput,
    1,
    BacnetPropertyId.presentValue,
  );

  // REAL is inferred for analog present values; null relinquishes.
  await client.writeProperty(
    1234,
    BacnetObjectType.analogOutput,
    1,
    BacnetPropertyId.presentValue,
    21.5,
    priority: 8,
  );

  await client.close();
}
```

### Server

```dart
final server = BacnetServer(config: const BacnetConfig(interface: 'eth0'));
await server.start();
await server.init(4194300, 'Gateway', vendorName: 'ACME');

await server.addObject(
  BacnetObjectType.analogInput,
  1,
  name: 'Supply Air Temperature',
  units: 62, // degrees Celsius
  covIncrement: 0.1,
);
await server.addObject(
  BacnetObjectType.multiStateValue,
  1,
  name: 'Mode',
  stateTexts: ['Off', 'Heat', 'Cool'],
  presentValue: 1,
);

// Push many values at once (one isolate message, one native call).
await server.updatePresentValues([
  for (final point in points)
    BacnetPresentValueUpdate(
      objectType: BacnetObjectType.analogInput,
      instance: point.instance,
      value: point.value,
    ),
]);

server.writeEvents.listen((write) {
  print('${write.objectType}:${write.instance} <- ${write.value}');
});
```

A process hosts one BACnet stack: clients and servers created in the same
process share it (reference counted, the first configuration wins).

## High-load guide

The worker isolate owns the native stack. It blocks in `poll()` on the
sockets (no timer polling) and is woken up immediately when the main isolate
sends work. Requests are queued per device and sent while transaction slots
are free:

| Setting | Default | Purpose |
| --- | --- | --- |
| `maxConcurrentRequests` | 200 | Outstanding confirmed requests (≤ 250 invoke ids). |
| `maxConcurrentRequestsPerDevice` | 4 | Protects small controllers and MS/TP routers. |
| `maxQueuedRequests` | 10 000 | Back pressure: excess calls fail fast with `BacnetQueueFullException`. |
| `requestTimeout` | 30 s | Deadline including queueing and retries. |
| `apduTimeout` / `maxRetries` | 3 s / 3 | Per transmission timeout and retries. |
| `bindTimeout` | 5 s | Time to resolve an unknown device with Who-Is. |
| `socketBufferSize` | 4 MiB | Avoids drops during I-Am storms and bursts. |
| `covScanInterval` | 50 ms | Server side change-of-value detection. |
| `strictSourceCheck` | true | Drops replies whose source differs from the target. |

Recommendations:

- Fire requests concurrently (`Future.wait`, streams); the scheduler keeps
  the network load within the limits.
- Prefer `readMultiple` for many properties of one device; oversized
  requests are split automatically.
- Prefer COV (`PropertyMonitor`) over polling; subscriptions are renewed
  and cancelled automatically, notifications carry the values.
- On servers use `updatePresentValues` for bulk updates.
- Watch `client.stats()` (queue length, in-flight requests, timeouts,
  dropped replies) in production.

### Benchmarks

Measured on a 4 vCPU Linux VM over the loopback interface (servers are
separate processes built with `dart build cli`):

| Scenario | Result |
| --- | --- |
| Client, 50 000 ReadProperty to 8 devices | 52 500 requests/s, 0 errors |
| Client, 10 000 ReadPropertyMultiple (20 values each) to 8 devices | 258 600 values/s |
| One server, 4 clients × 40 000 ReadProperty | ~128 000 requests/s, 0 errors, 10 MB RSS |
| Server, batch update of 10 000 present values | 2.5–3 ms (≈ 3.5 M values/s) |
| Client vs bacnet-stack `bacserv`, 1 000 ReadProperty | 78 ms |

Run them yourself with `benchmark/load_test.dart` and
`benchmark/server_benchmark.dart`.

## Architecture

```
 main isolate                       worker isolate                 native (C)
┌──────────────────────┐  commands  ┌───────────────────────┐ FFI ┌────────────────────┐
│ BacnetClient         │ ─────────► │ request scheduler     │ ──► │ engine             │
│ BacnetServer         │  + wakeup  │ (per device queues,   │     │ (event buffer,     │
│ DeviceScanner        │            │  limits, binding)     │     │  source checks,    │
│ PropertyMonitor      │ ◄───────── │ event decoding        │ ◄── │  timers)           │
└──────────────────────┘  batched   └───────────────────────┘     │ bacnet-stack 1.6.1 │
                          results                                 └────────────────────┘
```

- The C engine (`native/src`) wraps bacnet-stack: confirmed requests are
  sent with pre-encoded service data, every network event is appended to an
  event buffer which Dart drains after each poll — no callbacks cross the
  FFI boundary.
- Services are encoded/decoded in Dart (`lib/src/codec`) with a bounds
  checked reader.
- Server requests are answered by bacnet-stack without running Dart code.

## Error handling

```dart
try {
  await client.readProperty(1234, BacnetObjectType.analogInput, 1,
      BacnetPropertyId.presentValue);
} on BacnetProtocolException catch (e) {
  print('${BacnetErrorClass.getName(e.errorClass)}: '
      '${BacnetErrorCode.getName(e.errorCode)}');
} on BacnetRejectException catch (e) {
  print('rejected: ${BacnetRejectReason.getName(e.reason)}');
} on BacnetAbortException catch (e) {
  print('aborted: ${BacnetAbortReason.getName(e.reason)}');
} on BacnetDeviceNotFoundException catch (e) {
  print('device ${e.deviceId} did not answer Who-Is');
} on BacnetTimeoutException {
  print('no answer');
} on BacnetQueueFullException {
  print('slow down');
}
```

## Values

`readProperty` returns `double` (REAL), `int` (Unsigned, Signed,
Enumerated), `bool`, `String`, `BacnetObject` (object identifiers),
`BacnetBitString`, `BacnetDate`, `BacnetTime`, `Uint8List` (octet strings),
`null`, or a `List` for arrays and lists.

Writes infer the datatype from the object type, the property and the Dart
value. Force it with `tag:` or a `BacnetValue`:

```dart
await client.writeProperty(1234, BacnetObjectType.binaryOutput, 1,
    BacnetPropertyId.presentValue, const BacnetValue.enumerated(1),
    priority: 8);
```

## Migrating from 0.0.x

- The package is a pure Dart package with a build hook: remove platform
  specific setup; Dart 3.11/Flutter 3.44 are required.
- `readProperty` returns `BacnetObject` instead of `{'type', 'instance'}`
  maps for object identifiers and complete lists for array properties.
- `writeProperty(tag:)` defaults to datatype inference instead of REAL.
- `BacnetClient.events` is a `Stream<WorkerResponse>`; use `iAmStream` and
  `covNotifications` for typed streams. COV notifications now include the
  initiating device and the values.
- `subscribeCOV` completes when the device acknowledged the subscription;
  pass `processId`/`lifetime` and cancel with `unsubscribeCOV`.
- `WriteNotificationResponse.value` is decoded; the raw bytes are in
  `rawValue`.
- Internal request/response classes (`WhoIsRequest`, `ReadPropertyRequest`,
  ...) were removed from the public API.
- `dispose()` releases the shared stack; prefer `await close()`.

## License

The plugin is MIT licensed. It bundles bacnet-stack, licensed
GPL-2.0-or-later WITH GCC-exception-2.0, which allows linking it into
proprietary applications; changes to bacnet-stack itself must be published.
See `native/bacnet-stack/license`.
