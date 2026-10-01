# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - Unreleased

Alarms and events. See *Migrating from 0.2.x* in the README.

### Added

- **Client — alarms and events**: `eventNotifications` delivers
  `EventNotificationEvent`s (confirmed and unconfirmed) with the values of
  the event algorithm as the sealed `BacnetEventValues`
  (`BacnetOutOfRangeValues`, `BacnetChangeOfStateValues`,
  `BacnetChangeOfValueValues`, `BacnetBufferReadyValues`,
  `BacnetChangeOfReliabilityValues` and the other algorithms;
  `BacnetOtherEventValues` for the rest). `acknowledgeAlarm` and
  `acknowledgeEvent` (AcknowledgeAlarm), `getEventInformation` (follows
  More_Events) with `BacnetEventSummary`, `getAlarmSummary` with
  `BacnetAlarmSummary`.
- **Client — lists**: `addListElement`/`removeListElement` and the typed
  `addListElements`/`removeListElements`, e.g. to add this client to the
  Recipient_List of a Notification Class.
- **Types**: `BacnetDestination`, the sealed `BacnetRecipient`
  (`BacnetRecipient.device`, `BacnetRecipient.ip`), `BacnetDaysOfWeek`,
  `BacnetEventPriorities`, `BacnetEventTransition`, `BacnetPropertyState`,
  and the enumerations `BacnetEventType`, `BacnetNotifyType` and
  `BacnetPropertyStateKind`. Typed properties `recipientList`, `priority`,
  `ackRequired`, `notifyType`, `eventDetectionEnable`,
  `eventMessageTexts` and `binaryAlarmValue`.
- **Server — intrinsic reporting**: Notification Class objects
  (`addNotificationClass`, instances 0..63) and `enableEventReporting`
  for Analog and Binary Inputs and Values (OUT_OF_RANGE and
  CHANGE_OF_STATE, faults from Reliability). The server sends event and
  acknowledgement notifications to the recipients (unconfirmed and
  confirmed, device recipients resolved with Who-Is) and answers
  AcknowledgeAlarm, GetEventInformation, GetAlarmSummary and
  Add/RemoveListElement.
- **Testing**: fake devices simulate event reporting
  (`FakeBacnetDevice.addNotificationClass`,
  `FakeBacnetObject.enableEventReporting`, `reportEvent`), acknowledgements,
  event information, alarm summaries and list services.

### Changed

- **Breaking**: event notifications are `EventNotificationEvent`s instead
  of `UnconfirmedServiceEvent`s; `BacnetEvent` has a new subclass.

### Fixed

- `write` and `addListElements` (client, server and fake) accept an `int`
  for a `double` property: `client.write(id, output,
  BacnetProperties.analogPresentValue, 35)` inferred `num` and failed with
  a `TypeError`. `BacnetWritableProperty.encodeValue` converts and checks
  values.
- Invoke ids of confirmed notifications of the server that timed out are
  released.

## [0.2.0] - 2026-10-01

Typed identifiers and values, read coalescing, segmentation and request
control. Breaking changes are marked; see *Migrating from 0.1.x* in the
README.

### Changed

- **Breaking — typed identifiers**: `BacnetObjectType`, `BacnetPropertyId`,
  `BacnetEngineeringUnits`, error classes/codes, reasons, services and the
  other enumerations are extension types over `int`. The client, server,
  models, events and exceptions use them, so a property id passed as an
  object type no longer compiles; `.label` names a value.
- **Breaking — typed values**: property values are the sealed class
  `BacnetValue` with one subclass per BACnet datatype (`BacnetReal`,
  `BacnetUnsigned`, `BacnetEnumerated`, `BacnetCharacterString`,
  `BacnetObject`, `BacnetList`, ...); no public API returns or accepts
  `dynamic` or `Object?` values any more:
  - `readProperty` (client and server) returns `Future<BacnetValue>`;
    Unsigned and Enumerated are no longer both decoded to `int`, and NULL
    is `BacnetNull` instead of `null`. Accessors `asDouble`, `asInt`,
    `asBool`, `asString`, `asStatusFlags` and `asList`.
  - `readMultiple` and `DeviceScanner.scanDevice` return
    `Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>`
    (a `BacnetValue` or a `BacnetError` per property; `valueOf`/`errorOf`)
    instead of `'type:instance'` → `int` → `dynamic` maps, and reject
    specifications that request a property twice.
  - `writeProperty`, `BacnetPropertyValue`, `BacnetServer.setPresentValue`,
    `setProperty`, `addObject` and `BacnetPresentValueUpdate` take a
    `BacnetValue`; the `tag:` parameters are removed.
    `BacnetValue.infer` converts untyped input explicitly.
  - `BacnetObject` is an identifier and the ObjectIdentifier value; its
    `properties` map and the getters based on it are removed.
  - `CovNotificationEvent.values` is `Map<BacnetPropertyId, BacnetValue>`
    (`presentValue`, `statusFlags`); `PropertyWriteEvent.value` is a
    `BacnetValue?`.
  - `PropertyUpdate` is sealed: `PropertyValueUpdate` and
    `PropertyErrorUpdate` (with a `BacnetException`).
  - `TrendLogEntry` has a sealed `datum` (`TrendLogValue`,
    `TrendLogStatus`, `TrendLogFailure`, `TrendLogTimeChange`) and
    `BacnetStatusFlags? statusFlags` instead of `value` and `status`.
  - `readRange` takes a sealed `BacnetRange` instead of
    `type`/`reference`/`count`; `ReadRangeType` is removed.
  - `BacnetError` moved next to the values; `BacnetBitString`,
    `BacnetDate`, `BacnetTime` are `BacnetValue`s.
- **Breaking**: `scanDevice` takes `background`/`cancelToken` instead of
  the ignored `endDeviceId`.
- `DeviceScanner` sends background requests by default (`background`).
- **Breaking**: I-Have, UnconfirmedTextMessage and
  UnconfirmedPrivateTransfer arrive as typed events;
  `UnconfirmedServiceEvent` remains for event notifications and requests
  that cannot be decoded.
- **Dependencies**: bacnet-stack 1.7.0-rc4 (security fixes for BVLC header
  encoding, enclosed data and constructed value decoding); the server
  object table gains Averaging, and Accumulator supports COV.
- Request methods use callbacks instead of `async` functions (see
  *Fixed*); 50 000 concurrent reads run at 170–196k reads/s (AOT,
  loopback) instead of 123–138k.

### Added

- **Read coalescing**: concurrent `readProperty` calls to one device are
  merged into ReadPropertyMultiple requests (`coalesceReads`,
  `maxCoalescedReads`, `coalescingWindow`); identical reads share one
  result, devices without RPM support are detected. 50 000 concurrent
  reads need 24× fewer requests and run about 3× faster on loopback.
- **Segmentation**: segmented ComplexACKs (large object lists, schedules,
  RPM results) are acknowledged window by window, reassembled and decoded
  like unsegmented answers; lost segments are requested again and stalled
  transfers time out. Requests advertise `maxSegmentsAccepted` (default 32,
  0 disables). `BacnetStats.segmentedReplies` counts them.
- **Background requests**: `background: true` queues requests behind
  interactive ones and limits them to 3/4 of the transaction slots and one
  slot less per device.
- **Offline devices**: after `offlineAfterTimeouts` consecutive timeouts
  requests to a device fail immediately with `BacnetDeviceOfflineException`
  (a `BacnetTimeoutException`); one request probes it after
  `offlineRetryInterval` (doubling while it stays silent), an I-Am brings
  it back. `BacnetStats.offlineDevices` counts them.
- **Cancellation**: `BacnetCancelToken` cancels reads, writes, ReadRange
  and raw requests (`BacnetCancelledException`); queued requests are
  dropped from the worker queue.
- **Testing**: `package:bacnet_plugin/testing.dart` with
  `FakeBacnetClient`, `FakeBacnetDevice` and `FakeBacnetObject`: in-memory
  devices with discovery, real error codes, priority arrays, COV
  notifications, trend log records, latency and offline simulation, and a
  request log for assertions.
- **Typed properties**: `BacnetProperty<T>`/`BacnetWritableProperty<T>`
  and the `BacnetProperties` catalogue of standard properties;
  `client.read`/`client.write` (also on `BacnetServer` and
  `FakeBacnetClient`) return and accept the Dart type, read-only
  properties cannot be written, and `get` reads `readMultiple` results.
- **Constructed datatypes**: `BacnetWeeklySchedule`, `BacnetTimeValue`,
  `BacnetSpecialEvent`, `BacnetCalendarEntry`, `BacnetDateRange`,
  `BacnetWeekNDay`, `BacnetDateTime`, `BacnetTimeStamp`,
  `BacnetDeviceObjectPropertyReference`, `BacnetAddressBinding`,
  `BacnetPriorityArray`, `BacnetEventTransitionBits` and
  `BacnetLimitEnable` convert from and to the values of schedules,
  calendars, trend logs and event reporting. Checked against
  bacnet-stack's `bacserv`.
- **Typed service events**: `IHaveEvent`, `TextMessageEvent` and
  `PrivateTransferEvent` instead of raw `UnconfirmedServiceEvent`s;
  `sendWhoHas` (answered by `FakeBacnetDevice`s too).
- JSON for values, write specifications and trend logs
  (`{"datatype": "real", "value": 21.5}`).
- Constants `BacnetBinaryPV` and `BacnetPolarity`.

### Fixed

- In JIT mode (debug builds, `dart run`) bursts of tens of thousands of
  requests stalled for seconds: the client kept one suspended `async` call
  per request, and the VM deoptimizes each of them separately when the
  function's optimized code is invalidated. Request methods now use
  callbacks; non-BACnet errors of merged reads fail the reads instead of
  escaping as uncaught errors.
- Unsigned and Enumerated values of 64 bits wrapped to negative numbers;
  they are now rejected with `BacnetDecodeException`.
- Datatype inference wrote REAL to Accumulator present values (Unsigned).

## [0.1.0] - 2026-10-01

Reworked for high-load client and server deployments. See the migration
notes in the README.

### Changed

- **Dependencies**: bacnet-stack 1.6.1 pinned as git submodule (previously
  an unpinned clone of `master`); Dart SDK `^3.11.0`; `ffi` 2.2,
  `json_annotation` 4.12, `meta` 1.16+, `hooks` 2.2, `code_assets` 2.1,
  `native_toolchain_c` 0.19, `ffigen` 22, `build_runner` 2.16,
  `json_serializable` 6.14, `mocktail` 1.0.5, `test` 1.30+, `lints` 6.1;
  example: `go_router` 18, `provider` 6.1.5;
  CI actions `checkout@v7`, `setup-dart@v1`, `flutter-action@v2`,
  `setup-java@v6`.
- **Build**: the native library is compiled by `hook/build.dart` for all
  platforms (`@Native` bindings). The package no longer depends on Flutter
  and runs in plain Dart programs. Removed the per-platform CMake, Gradle
  and CocoaPods files, which were broken (Android CMake path, iOS/macOS
  sources, Linux bundling, Windows-only native code).
- **Native engine** rewritten (`native/src`): portable C (no `windows.h`,
  SEH or `setjmp`), event buffer instead of FFI callbacks, wake-up socket,
  generic confirmed request sender, own BACnet/IP port for POSIX systems
  based on `getifaddrs` (accepts interface names and IPv4 addresses).
- **Worker isolate**: blocks on the sockets instead of a 10 ms timer that
  processed one packet per tick (~100 packets/s); processes up to 256
  packets per iteration and batches messages to the main isolate.
- **Client**: request scheduler with `maxConcurrentRequests`,
  `maxConcurrentRequestsPerDevice`, `maxQueuedRequests` and deadlines;
  automatic address binding via targeted Who-Is; ReadPropertyMultiple is
  split automatically when the answer exceeds the APDU size; datatype
  inference for writes (`BacnetValue` to force a type).
- **Server**: answers Who-Is, Read/WriteProperty(Multiple),
  SubscribeCOV(Property), ReadRange, DCC, ReinitializeDevice and time
  synchronization; COV notifications are detected and sent (full scan every
  `covScanInterval`); objects with names, descriptions, units, COV
  increments and state texts; `setPresentValue`, `updatePresentValues`,
  `setProperty`, `readProperty`, `removeObject`, `sendIAm`.
- `DeviceScanner` and `PropertyMonitor` run requests in parallel;
  COV subscriptions are renewed and cancelled, notifications carry values.
- `BacnetClient` and `BacnetServer` share one reference counted stack.
- **Events** form the sealed `BacnetEvent` hierarchy (`IAmEvent`,
  `CovNotificationEvent`, `PropertyWriteEvent`, `UnconfirmedServiceEvent`,
  `LogEvent`, `ErrorEvent`); the `*Response` names of 0.0.x are deprecated
  aliases. Internal request/response classes are no longer exported.
- **Constants** are generated from bacnet-stack (`tool/generate_constants.dart`)
  and cover every standard object type, property, error code and service;
  existing names are unchanged.
- **Internals** reorganized for maintainability: codec, worker isolate
  (engine facade, event reader, unit tested request scheduler) and the C
  engine are split into focused modules; tests mirror `lib/src`; stricter
  lints.

### Fixed

- TSM timer was fed with wall clock timestamps instead of elapsed time,
  so requests timed out and were retransmitted almost immediately.
- Failed transactions never released their invoke id; after 255 failures
  no request could be sent anymore.
- Errors, rejects and aborts were not reported (requests waited for the
  15 s timeout); requests to unknown devices never completed.
- I-Am did not add address bindings (`address_add_binding` only updates
  existing entries) and routed devices lost their network address.
- Confirmed COV notifications were never acknowledged; COV notifications
  had no device id, so `PropertyMonitor` never matched them.
- WriteProperty sent the priority as array index; WPM forced REAL values.
- Server object names/vendor name pointed to freed memory; value objects
  rejected writes; demo objects of bacnet-stack were exposed.
- RPM/ReadRange decoders could read past the received data; ReadRange
  item data used the wrong context tag; malformed UCS-4 strings threw.
- JSON serialization of nested models.

### Added

- Typed exceptions: `BacnetRejectException`, `BacnetAbortException`,
  `BacnetDeviceNotFoundException`, `BacnetQueueFullException`,
  `BacnetDecodeException`, `BacnetEncodeException`.
- `BacnetStats`, `client.stats()`, `iAmEvents`, `covEvents`,
  `readRange`, `getTrendLog` (decoded log records), `timeSynchronization`,
  `sendConfirmedRaw`, `removeDeviceBinding`, `isDeviceBound`,
  `unsubscribeCOV`, `CallbackLogger`.
- Value types `BacnetBitString`, `BacnetStatusFlags`, `BacnetDate`,
  `BacnetTime`, `BacnetValue`.
- Constants `BacnetEngineeringUnits`, `BacnetEventState`,
  `BacnetReliability`, `BacnetDeviceStatus`, `BacnetSegmentation`,
  `BacnetAbortReason`, `BacnetRejectReason`, `BacnetConfirmedService`,
  `BacnetUnconfirmedService`; `values` lists the known values of each.
- Unit tests (codec vectors from ASHRAE 135 Annex F, fuzzing), loopback
  client/server integration tests, load and server benchmarks, interop
  checks against the bacnet-stack demo tools.

## [0.0.3] - 2026-01-09

### Changed

- Removed unit tests execution from CI workflow configuration.

## [0.0.2] - 2026-01-08

### Fixed

- Fixed internal tooling and configuration.

## [0.0.1] - 2026-01-07

### Added

#### Core Features

- **BACnet Client** - Full client implementation with support for:
  - Device discovery (Who-Is/I-Am)
  - Read Property / Read Property Multiple
  - Write Property / Write Property Multiple
  - Change of Value (COV) subscriptions
  - Foreign Device Registration
  - Device scanning and object enumeration
- **BACnet Server** - Server implementation for hosting objects:
  - Device initialization
  - Object hosting (Analog, Binary, Multi-state)
  - Write notification events
  - Read/Write property handling

#### Developer Experience

- **Named Constants** - Complete set of BACnet protocol constants:

  - `BacnetObjectType` - 25+ object types with human-readable names
  - `BacnetPropertyId` - 80+ property identifiers
  - `BacnetErrorClass` and `BacnetErrorCode` - Comprehensive error constants

- **Modern Logging**:

  - `DeveloperBacnetLogger` - Dart DevTools integration
  - `ConsoleBacnetLogger` - Simple console output
  - Pluggable logger interface for custom implementations

- **Type Safety**:

  - Strict type checking throughout
  - Named constants replace magic numbers
  - Comprehensive parameter documentation

- **JSON Serialization**:
  - All models support `toJson()`/`fromJson()`
  - Generated with `json_serializable`
  - Easy API integration

#### Data Models

- **Immutable Models**:

  - `BacnetObject` - Object representation with properties
  - `BacnetPropertyReference` - Property references for RPM
  - `BacnetReadAccessSpecification` - RPM request specification
  - `BacnetWriteAccessSpecification` - WPM request specification
  - `BacnetPropertyValue` - Property values for WPM

- **Model Features**:
  - `@immutable` annotations
  - `copyWith()` methods for updates
  - Equality operators (`==`, `hashCode`)
  - Helper getters (name, presentValue, etc.)
  - Full dartdoc documentation

#### Configuration

- **BacnetConfig** - Centralized configuration:
  - Interface binding
  - Port configuration
  - Timeout settings
  - Retry configuration
  - Logger selection

#### Error Handling

- **Exception Hierarchy**:
  - `BacnetException` - Base exception
  - `BacnetTimeoutException` - Request timeouts
  - `BacnetNotInitializedException` - Uninitialized operations
  - `BacnetProtocolException` - Protocol errors with error codes

#### Documentation

- **Complete API Documentation**:

  - Every public API has dartdoc comments
  - Usage examples for all major features
  - Parameter explanations with constant references
  - Return value documentation

- **Project Documentation**:
  - Comprehensive README.md with examples
  - CONTRIBUTING.md guide
  - Architecture diagrams
  - Quick start guides

#### Code Quality

- **Linting**:

  - 100+ lint rules configured
  - Strict type checking enabled
  - Code style enforcement (single quotes, const, etc.)
  - Documentation requirements

- **Code Generation**:
  - `build_runner` integration
  - JSON serialization generation
  - FFI bindings generation

### Architecture

- **Isolate-Based Design**:
  - Non-blocking network operations
  - Smooth UI performance
  - Background processing
  - Worker isolate for native BACnet stack

### Platforms

- ✅ Windows
- ✅ Linux
- ✅ macOS
- ✅ Android
- ✅ iOS

### Dependencies

- `ffi: ^2.1.4` - Foreign Function Interface
- `json_annotation: ^4.9.0` - JSON annotations
- `meta: ^1.15.0` - Metadata annotations
- `plugin_platform_interface: ^2.1.8` - Platform interface

### Dev Dependencies

- `build_runner: ^2.4.0` - Code generation
- `json_serializable: ^6.8.0` - JSON serialization
- `mocktail: ^1.0.0` - Mocking for tests
- `flutter_lints: ^6.0.0` - Linting rules

### Known Limitations

- Trend log reading returns dummy data (planned for future release)
- Device scanning limited to first 10 objects
- Some native worker code lacks public documentation
- WritePropertyMultiple native binding pending implementation

## [Unreleased]

### Planned Features

- Complete trend log implementation
- Device scanner utility class
- Property monitor with automatic polling
- Enhanced example app with UI
- Unit test suite (>80% coverage)
- API reference documentation
- More integration tests

---

[0.0.1]: https://github.com/gencto/bacnet_plugin/releases/tag/v0.0.1
[Unreleased]: https://github.com/gencto/bacnet_plugin/compare/v0.0.1...HEAD
