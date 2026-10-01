# BACnet Plugin

[![pub package](https://img.shields.io/pub/v/bacnet_plugin.svg)](https://pub.dev/packages/bacnet_plugin)
[![CI](https://github.com/gencto/bacnet_plugin/actions/workflows/ci.yml/badge.svg)](https://github.com/gencto/bacnet_plugin/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

High-throughput BACnet/IP **client and server** for Dart and Flutter, built
on [bacnet-stack](https://github.com/bacnet-stack/bacnet-stack) 1.7 through
FFI. Works in Flutter apps (Android, iOS, Linux, macOS, Windows) and in plain
Dart programs such as headless gateways and supervisory services.

## Features

- **Client**: Who-Is/I-Am discovery, ReadProperty, ReadPropertyMultiple
  (split automatically when the answer exceeds the device's APDU),
  segmented answers (large object lists, schedules, RPM results) reassembled
  transparently,
  WriteProperty(Multiple) with datatype inference, SubscribeCOV(Property)
  with decoded notifications, ReadRange/Trend Logs, alarms and events
  (typed event notifications, AcknowledgeAlarm, GetEventInformation,
  GetAlarmSummary, Add/RemoveListElement), time synchronization, foreign
  device registration and raw confirmed services.
- **Server**: hosts Analog/Binary/Multi-state Input/Output/Value, Integer,
  Positive Integer, CharacterString Value and Notification Class objects;
  answers Who-Is, Read/WriteProperty(Multiple), SubscribeCOV(Property),
  ReadRange, Add/RemoveListElement, DeviceCommunicationControl and
  ReinitializeDevice natively; reports alarms of analog and binary objects
  (intrinsic reporting) and answers AcknowledgeAlarm, GetEventInformation
  and GetAlarmSummary; batch updates of present values; write
  notifications.
- **Built for load**: request scheduler with global and per-device
  concurrency limits, back pressure, automatic address binding, concurrent
  reads merged into ReadPropertyMultiple, batched isolate messaging and
  zero-copy event processing.
- **Robust**: bounds-checked decoder (fuzz tested), typed exceptions,
  protection against late replies with recycled invoke ids, no
  `exit()`/`longjmp` tricks in native code.
- **Modern build**: native code is compiled by a
  [build hook](https://dart.dev/tools/hooks) for every platform — no CMake,
  Gradle or CocoaPods configuration in the package.

## Installation

```yaml
dependencies:
  bacnet_plugin: ^0.4.0
```

Requirements:

- Dart 3.11+ / Flutter 3.44+ (build hooks).
- A C compiler on the build machine: Xcode (macOS/iOS), Visual Studio with
  the C++ workload (Windows), clang or gcc (Linux), the Android NDK
  installed by Flutter (Android).
- Git dependencies must be fetched with submodules
  (`native/bacnet-stack` is pinned to a reviewed bacnet-stack commit); the pub.dev
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

  client.iAmEvents.listen((iAm) {
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
  print(temperature.asDouble); // null if the device sent another datatype

  // The value class is the BACnet datatype; BacnetNull() relinquishes.
  await client.writeProperty(
    1234,
    BacnetObjectType.analogOutput,
    1,
    BacnetPropertyId.presentValue,
    const BacnetReal(21.5),
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
  units: BacnetEngineeringUnits.degreesCelsius,
  covIncrement: 0.1,
);
await server.addObject(
  BacnetObjectType.multiStateValue,
  1,
  name: 'Mode',
  stateTexts: ['Off', 'Heat', 'Cool'],
  presentValue: const BacnetUnsigned(1),
);

// Push many values at once (one isolate message, one native call).
await server.updatePresentValues([
  for (final point in points)
    BacnetPresentValueUpdate(
      objectType: BacnetObjectType.analogInput,
      instance: point.instance,
      value: BacnetReal(point.value),
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
| `coalesceReads` | true | Merges concurrent `readProperty` calls per device into ReadPropertyMultiple. |
| `maxCoalescedReads` | 24 | Properties per merged request (lower it for MS/TP devices). |
| `requestTimeout` | 30 s | Deadline including queueing and retries. |
| `apduTimeout` / `maxRetries` | 3 s / 3 | Per transmission timeout and retries. |
| `bindTimeout` | 5 s | Time to resolve an unknown device with Who-Is. |
| `offlineAfterTimeouts` | 3 | Consecutive timeouts after which requests to a device fail fast. |
| `offlineRetryInterval` | 30 s | Pause before an offline device is probed again (doubles up to 8×). |
| `maxSegmentsAccepted` | 32 | Segments accepted per answer (0 disables segmented answers). |
| `socketBufferSize` | 4 MiB | Avoids drops during I-Am storms and bursts. |
| `covScanInterval` | 50 ms | Server side change-of-value detection. |
| `strictSourceCheck` | true | Drops replies whose source differs from the target. |

Recommendations:

- Fire requests concurrently (`Future.wait`, streams); the scheduler keeps
  the network load within the limits and concurrent reads of a device
  travel together in ReadPropertyMultiple requests.
- Prefer `readMultiple` for many properties of one device; oversized
  requests are split automatically.
- Mark bulk work (`background: true`, `DeviceScanner` does it by default):
  it waits behind interactive requests and never takes all transaction
  slots, so the UI stays responsive during a site scan.
- Cancel requests nobody waits for any more with a `BacnetCancelToken`
  (e.g. when a screen closes); queued requests are dropped.
- Dead controllers do not slow down the rest of the site: after
  `offlineAfterTimeouts` timeouts their requests fail at once with
  `BacnetDeviceOfflineException` until a probe or an I-Am succeeds.
- Prefer COV (`PropertyMonitor`) over polling; subscriptions are renewed
  and cancelled automatically, notifications carry the values.
- On servers use `updatePresentValues` for bulk updates.
- Watch `client.stats()` (queue length, in-flight requests, timeouts,
  dropped replies) in production.

### Benchmarks

Measured on a 4 vCPU Linux VM over the loopback interface (servers and the
load generator are separate processes built with `dart build cli`):

| Scenario | Result |
| --- | --- |
| Client, 50 000 concurrent `readProperty` to 4 devices (merged into 2 084 RPM) | 170 000–196 000 reads/s, 0 errors |
| Same with `coalesceReads: false` (50 000 ReadProperty) | 58 000–68 000 requests/s |
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
└──────────────────────┘  batched   └───────────────────────┘     │ bacnet-stack 1.7   │
                          results                                 └────────────────────┘
```

- The C engine (`native/src`) wraps bacnet-stack: confirmed requests are
  sent with pre-encoded service data, every network event is appended to an
  event buffer which Dart drains after each poll — no callbacks cross the
  FFI boundary.
- Services are encoded/decoded in Dart (`lib/src/codec`) with a bounds
  checked reader.
- Server requests are answered by bacnet-stack without running Dart code.
- Segmented answers to client requests are reassembled by the engine
  (`native/src/bp_segments.c`), since the transaction state machine of
  bacnet-stack does not implement segmentation. The server cannot send
  segmented answers: requests whose answer exceeds the client's APDU are
  aborted with segmentation-not-supported.

## Error handling

```dart
try {
  await client.readProperty(1234, BacnetObjectType.analogInput, 1,
      BacnetPropertyId.presentValue);
} on BacnetProtocolException catch (e) {
  print('${e.errorClass.label}: ${e.errorCode.label}');
} on BacnetRejectException catch (e) {
  print('rejected: ${e.reason.label}');
} on BacnetAbortException catch (e) {
  print('aborted: ${e.reason.label}');
} on BacnetDeviceNotFoundException catch (e) {
  print('device ${e.deviceId} did not answer Who-Is');
} on BacnetDeviceOfflineException catch (e) {
  print('device ${e.deviceId} is offline, retry in ${e.retryAfter}');
} on BacnetTimeoutException {
  print('no answer');
} on BacnetQueueFullException {
  print('slow down');
} on BacnetCancelledException {
  // cancelled with a BacnetCancelToken
}
```

## Identifiers

Object types, property identifiers, units, error classes and the other
BACnet enumerations are [extension types](https://dart.dev/language/extension-types)
over `int`: they cost nothing at runtime, work wherever an `int` is expected,
and the compiler rejects a property where an object type is expected.
Values this package does not name (proprietary types and properties) are
created explicitly:

```dart
await client.readProperty(
  1234,
  const BacnetObjectType(130), // proprietary object type
  1,
  const BacnetPropertyId(512), // proprietary property
);
print(BacnetObjectType.multiStateValue.label); // Multi-state Value
```

## Values

Property values are a sealed class, `BacnetValue`, with one subclass per
BACnet datatype. Nothing in the API is `dynamic` or `Object?`: reads say
what they return, writes say which datatype goes on the wire, and the
compiler checks that a `switch` handles every case.

| BACnet datatype | Class | Dart value |
| --- | --- | --- |
| Null | `BacnetNull` | |
| Boolean | `BacnetBoolean` | `bool` |
| Unsigned / Signed | `BacnetUnsigned` / `BacnetSigned` | `int` |
| Real / Double | `BacnetReal` / `BacnetDouble` | `double` |
| OctetString | `BacnetOctetString` | `Uint8List` |
| CharacterString | `BacnetCharacterString` | `String` |
| BitString | `BacnetBitString` | `List<bool>` |
| Enumerated | `BacnetEnumerated` | `int` |
| Date / Time | `BacnetDate` / `BacnetTime` | fields, `null` = unspecified |
| ObjectIdentifier | `BacnetObject` | `type`, `instance` |
| array or list | `BacnetList` | `List<BacnetValue>` |
| other constructed data | `BacnetConstructedValue`, `BacnetContextValue` | raw |

```dart
final value = await client.readProperty(1234,
    BacnetObjectType.analogInput, 1, BacnetPropertyId.presentValue);
switch (value) {
  case BacnetReal(:final value):
    print('$value °C');
  case BacnetNull():
    print('no value');
  default:
    print('unexpected $value');
}

// Accessors return null for any other datatype.
value.asDouble; // Real, Double, Unsigned, Signed
value.asInt; // Unsigned, Signed, Enumerated
value.asString; // CharacterString
value.asStatusFlags; // BitString as BacnetStatusFlags
value.asList; // elements of a BacnetList, or [value]
```

A device sends an array with one element exactly like a single value, so
use `asList` for arrays and lists (Object_List, Priority_Array, ...).

`readMultiple` returns, per object and property, a `BacnetPropertyResult`:
a `BacnetValue` or a `BacnetError` for a property the device could not
return.

```dart
const sensor =
    BacnetObject(type: BacnetObjectType.analogInput, instance: 1);
final results = await client.readMultiple(1234, [
  const BacnetReadAccessSpecification(
    objectIdentifier: sensor,
    properties: [
      BacnetPropertyReference(
          propertyIdentifier: BacnetPropertyId.objectName),
      BacnetPropertyReference(
          propertyIdentifier: BacnetPropertyId.presentValue),
    ],
  ),
]);
final properties = results[sensor] ?? const {};
print(properties.valueOf(BacnetPropertyId.objectName)?.asString);
switch (properties[BacnetPropertyId.presentValue]) {
  case BacnetReal(:final value):
    print('$value °C');
  case BacnetError(:final errorCode):
    print('not readable: ${errorCode.label}');
  case _:
    print('missing or unexpected');
}
```

Writes encode the datatype of the value class:

```dart
await client.writeProperty(1234, BacnetObjectType.binaryOutput, 1,
    BacnetPropertyId.presentValue,
    const BacnetEnumerated(BacnetBinaryPV.active), priority: 8);
await client.writeProperty(1234, BacnetObjectType.binaryOutput, 1,
    BacnetPropertyId.presentValue, const BacnetNull(),
    priority: 8); // relinquish
```

For values whose type is only known at run time (user input,
configuration files) `BacnetValue.infer` picks the datatype from the object
type, the property and the Dart value, and throws an `ArgumentError` when
it cannot:

```dart
final value = BacnetValue.infer(
  double.parse(input),
  objectType: BacnetObjectType.analogValue,
  propertyId: BacnetPropertyId.presentValue,
); // BacnetReal
```

Other typed results:

- `CovNotificationEvent.values` is a `Map<BacnetPropertyId, BacnetValue>`
  with `presentValue` and `statusFlags` getters.
- `PropertyMonitor` emits a sealed `PropertyUpdate`: `PropertyValueUpdate`
  with the value or `PropertyErrorUpdate` with the `BacnetException`.
- Trend log entries hold a sealed `TrendLogDatum` (`TrendLogValue`,
  `TrendLogStatus`, `TrendLogFailure`, `TrendLogTimeChange`) and the
  `BacnetStatusFlags` of the record.
- `readRange` takes a sealed `BacnetRange` (`all`, `byPosition`,
  `bySequenceNumber`, `byTime`).

Values, write specifications and trend logs convert to and from JSON
(`toJson`, `fromJson`), e.g. `{"datatype": "real", "value": 21.5}`.

## Typed properties

`BacnetProperties` describes the standard properties with their
datatypes, so `read` returns the Dart type and `write` only accepts it.
Properties the standard defines as read-only cannot be written: writing
Status_Flags does not compile.

```dart
const sensor = BacnetObject(type: BacnetObjectType.analogInput, instance: 1);
final String name = await client.read(1234, sensor, BacnetProperties.objectName);
final units = await client.read(1234, sensor, BacnetProperties.units);
final flags = await client.read(1234, sensor, BacnetProperties.statusFlags);

const output = BacnetObject(type: BacnetObjectType.analogOutput, instance: 1);
await client.write(1234, output, BacnetProperties.analogPresentValue, 21.5,
    priority: 8);
final priorities = await client.read(1234, output, BacnetProperties.priorityArray);
print('${priorities.activeValue} @ ${priorities.activePriority}');
```

The constructed datatypes of schedules, calendars, trend logs and event
reporting are classes as well, read and written like any other value:

| Property | Type |
| --- | --- |
| Weekly_Schedule | `BacnetWeeklySchedule` (`BacnetTimeValue`s per day) |
| Exception_Schedule | `List<BacnetSpecialEvent>` |
| Date_List | `List<BacnetCalendarEntry>` (date, date range, week-n-day) |
| Effective_Period | `BacnetDateRange` |
| Start_Time, Stop_Time | `BacnetDateTime` |
| Event_Time_Stamps | `List<BacnetTimeStamp>` |
| Log_DeviceObjectProperty, List_Of_Object_Property_References | `BacnetDeviceObjectPropertyReference` |
| Priority_Array | `BacnetPriorityArray` |
| Event_Enable, Acked_Transitions, Limit_Enable | `BacnetEventTransitionBits`, `BacnetLimitEnable` |
| Device_Address_Binding | `List<BacnetAddressBinding>` |

```dart
const schedule = BacnetObject(type: BacnetObjectType.schedule, instance: 1);
final week = await client.read(1234, schedule, BacnetProperties.weeklySchedule);
final days = [for (final day in week.days) List.of(day)];
days[DateTime.monday - 1] = const [
  BacnetTimeValue(BacnetTime(hour: 7, minute: 0, second: 0, hundredths: 0),
      BacnetReal(21)),
  BacnetTimeValue(BacnetTime(hour: 18, minute: 0, second: 0, hundredths: 0),
      BacnetNull()),
];
await client.write(1234, schedule, BacnetProperties.weeklySchedule,
    BacnetWeeklySchedule(days));
```

Results of `readMultiple` have the same typed access:
`results[sensor]?.get(BacnetProperties.objectName)` (null for errors,
missing properties and other datatypes). Proprietary properties are
declared with `BacnetProperty.real(...)`, `BacnetWritableProperty.unsigned(...)`
and the other helpers.

Unconfirmed services arrive as typed events too: `IHaveEvent` (the answer
to `sendWhoHas`), `TextMessageEvent` and `PrivateTransferEvent`.

## Alarms and events

Devices report alarms and events to the recipients of a Notification
Class. `subscribeAlarms` adds this client (its `localAddress()`) to the
Recipient_List of a class and returns the subscription:

```dart
final alarms = await client.subscribeAlarms(1234, notificationClass: 1);
alarms.notifications.listen((event) async {
  print('${event.object}: ${event.fromState?.label} -> ${event.toState.label}');
  switch (event.eventValues) {
    case BacnetOutOfRangeValues(:final exceedingValue, :final exceededLimit):
      print('$exceedingValue is beyond $exceededLimit');
    case BacnetChangeOfStateValues(:final newState):
      print('new state ${newState.asBinaryPV?.label}');
    case final other:
      print(other);
  }
  if (event.ackRequired) {
    await client.acknowledgeEvent(event, source: 'operator');
  }
});
// ...
await alarms.cancel(); // removes the client from the Recipient_List
```

Devices without AddListElement get the destination written with
WriteProperty. `alarms.refresh()` adds it again when a device lost it
(e.g. after a restart). `client.eventNotifications` delivers the
notifications of all subscriptions; `addListElements` with
`BacnetProperties.recipientList` adds any `BacnetDestination` (another
recipient, a device recipient, confirmed notifications, selected days and
transitions).

The values of every event algorithm are a subclass of the sealed
`BacnetEventValues` (out of range, change of state, change of value,
buffer ready, change of reliability, ...). `getEventInformation` lists the
objects in alarm or with unacknowledged transitions, `getAlarmSummary` the
objects in alarm:

```dart
for (final summary in await client.getEventInformation(1234)) {
  for (final transition in summary.unacknowledgedTransitions) {
    await client.acknowledgeAlarm(1234, summary.object,
        summary.stateOf(transition), summary.timeStampOf(transition)!,
        source: 'operator');
  }
}
```

`addListElement`/`removeListElement` change any list property.

The server reports alarms of Analog and Binary Inputs and Values itself
(the event algorithms of bacnet-stack run every second):

```dart
await server.addNotificationClass(1, name: 'Alarms');
await server.addObject(BacnetObjectType.analogInput, 1, name: 'Room Temp');
await server.enableEventReporting(
  const BacnetObject(type: BacnetObjectType.analogInput, instance: 1),
  notificationClass: 1,
  highLimit: 26,
  lowLimit: 18,
  deadband: 0.5,
  timeDelay: const Duration(seconds: 30),
);
// clients add themselves to Recipient_List; values beyond the limits are
// reported to them and acknowledged with AcknowledgeAlarm
```

The server reports what clients change: `alarmAcknowledgements` (who
acknowledged which alarm) and `listElementEvents` (recipients added or
removed, e.g. to persist the Recipient_List; bacnet-stack keeps it in
memory only).

Notification Class instances 0..63 are available, with up to 10
recipients each. bacnet-stack keeps one destination per recipient: adding
a destination for a recipient that is already in the list replaces it.

## Testing your application

`package:bacnet_plugin/testing.dart` provides `FakeBacnetClient`, a
`BacnetClient` backed by in-memory devices. Code using the client,
`DeviceScanner` or `PropertyMonitor` runs unchanged in unit and widget tests,
without a network or the native stack:

```dart
import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/testing.dart';

final ahu = FakeBacnetDevice(1234, name: 'AHU-1')
  ..addObject(
    BacnetObjectType.analogInput,
    1,
    presentValue: const BacnetReal(21.5),
    units: BacnetEngineeringUnits.degreesCelsius,
  )
  ..addObject(BacnetObjectType.analogOutput, 1);
final client = FakeBacnetClient(devices: [ahu]);
await client.start();

// discovery, reads, writes with priorities and COV work as with a device
final devices = await DeviceScanner(client).discoverDevices(
  timeout: const Duration(milliseconds: 50),
);

// simulate the field and the network
ahu.object(BacnetObjectType.analogInput, 1)![BacnetPropertyId.presentValue] =
    const BacnetReal(23); // COV notification to subscribers
ahu.online = false; // requests time out
client.latency = const Duration(milliseconds: 200);

// assert what the application sent
expect(client.requests.where((r) => r.service == 'writeProperty'), isEmpty);
```

Fake devices report alarms to the clients in the Recipient_List of a
Notification Class, keep the event state for `getEventInformation` and
`getAlarmSummary` and check acknowledgements like a device.
`device.unsupportedServices` makes a device reject services, to test the
fallbacks of an application:

```dart
ahu.addNotificationClass(1);
final sensor = ahu.object(BacnetObjectType.analogInput, 1)!
  ..enableEventReporting(notificationClass: 1);
// after the application added itself to Recipient_List:
sensor.reportEvent(
  BacnetEventState.highLimit,
  eventValues: const BacnetOutOfRangeValues(
    exceedingValue: 31,
    statusFlags: BacnetStatusFlags(inAlarm: true),
    deadband: 1,
    exceededLimit: 30,
  ),
);
```

## Migrating from 0.3.x

- `AlarmAcknowledgedEvent` and `ListElementEvent` are new `BacnetEvent`
  subclasses: a `switch` over `BacnetEvent` needs cases for them.
- `BacnetEventSummary.isUnacknowledged` covers every transition; use
  `unacknowledgedTransitions` with `timeStampOf` and `stateOf` to
  acknowledge them.
- Classes implementing `BacnetClient` need `localAddress()`.

## Migrating from 0.2.x

- Event notifications arrive as `EventNotificationEvent` instead of
  `UnconfirmedServiceEvent`. A `switch` over `BacnetEvent` needs a case
  for it.
- `FakeBacnetClient` implements the new client methods; classes that
  implement `BacnetClient` themselves need them too.

## Migrating from 0.1.x

- Object types, property identifiers and other enumerations are typed:
  replace numbers such as `readProperty(id, 2, 1, 85)` with constants
  (`BacnetObjectType.analogValue`, `BacnetPropertyId.presentValue`) or
  `BacnetObjectType(2)`. `getName(value)` still works; prefer `.label`.
- Values are typed (see [Values](#values)): `readProperty` returns a
  `BacnetValue` instead of `dynamic`; `writeProperty`, `BacnetPropertyValue`
  and the server's `setPresentValue`, `setProperty`, `addObject` and
  `BacnetPresentValueUpdate` take one. The `tag:` parameters are gone: write
  `const BacnetEnumerated(1)` instead of `1, tag: BacnetApplicationTag.enumerated`,
  and use `BacnetValue.infer` for input whose type is only known at run
  time. `null` becomes `const BacnetNull()`.
- `readMultiple` and `DeviceScanner.scanDevice` return
  `Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>` instead
  of maps keyed by `'type:instance'` strings and `int`s:
  `results[object]?.valueOf(BacnetPropertyId.presentValue)`.
- `BacnetObject` is only an identifier (it no longer has `properties`) and
  is the ObjectIdentifier value.
- `PropertyUpdate` is sealed (`PropertyValueUpdate`/`PropertyErrorUpdate`);
  `TrendLogEntry` has a `datum` and `statusFlags` instead of `value` and a
  `status` string; `readRange` takes a `BacnetRange` instead of
  `type`/`reference`/`count`.
- `scanDevice(endDeviceId:)` is removed; pass `background`/`cancelToken`.

## Migrating from 0.0.x

- The package is a pure Dart package with a build hook: remove platform
  specific setup; Dart 3.11/Flutter 3.44 are required.
- `readProperty` returns `BacnetObject` instead of `{'type', 'instance'}`
  maps for object identifiers and complete lists for array properties.
- `writeProperty(tag:)` defaults to datatype inference instead of REAL.
- `BacnetClient.events` is a `Stream<BacnetEvent>`; use `iAmEvents` and
  `covEvents` for typed streams. COV notifications now include the
  initiating device and the values.
- `subscribeCOV` completes when the device acknowledged the subscription;
  pass `processId`/`lifetime` and cancel with `unsubscribeCOV`.
- `PropertyWriteEvent.value` is decoded; the raw bytes are in
  `rawValue`.
- Internal request/response classes (`WhoIsRequest`, `ReadPropertyRequest`,
  ...) were removed from the public API.
- `dispose()` releases the shared stack; prefer `await close()`.

## License

The plugin is MIT licensed. It bundles bacnet-stack, licensed
GPL-2.0-or-later WITH GCC-exception-2.0, which allows linking it into
proprietary applications; changes to bacnet-stack itself must be published.
See `native/bacnet-stack/license`.
