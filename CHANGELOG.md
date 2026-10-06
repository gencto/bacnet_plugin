# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] - 2026-10-06

Tools: the `bacnet` command line tool, device descriptions, shared COV
subscriptions in `PropertyMonitor`, fuzzing of the native engine. See
*Migrating from 0.7.x* in the README.

### Added

- **Command line tool** `bacnet` (`dart run bacnet_plugin:bacnet`):
  `discover`, `read`, `write` (values typed for the property, or
  `real:`/`unsigned:`/`enum:`/... prefixes), `objects`, `describe`,
  `watch` and `routers`, with `--json` output, `--address` instead of
  Who-Is and `--bbmd` for foreign device registration.
- **Device descriptions**: `client.describeDevice` reads every property of
  every object (ReadPropertyMultiple ALL, or Property_List and single
  reads for devices without it) into a `BacnetDeviceDescription` that
  stores as JSON and lists its objects in EPICS notation (`toEpics`).
- **PropertyMonitor** subscribes the monitored properties of a device that
  executes SubscribeCOVPropertyMultiple with one shared subscription
  (`useCovMultiple`, on by default), batched to the device's APDU size;
  properties the device refuses fall back to SubscribeCOV(Property) and
  polling.
- **Typed properties**: `protocolServicesSupported`
  (`Set<BacnetServiceSupported>`, new constants) and
  `protocolObjectTypesSupported` (`Set<BacnetObjectType>`).
- **Testing**: fake devices answer Protocol_Services_Supported (without
  `unsupportedServices`) and ReadPropertyMultiple with ALL, REQUIRED and
  OPTIONAL.
- **Native fuzzing**: `tool/fuzz_native.dart` builds a libFuzzer target of
  the engine (client and server handlers, segmentation, files, schedules,
  trend logs, backup) with AddressSanitizer and UndefinedBehaviorSanitizer.

### Fixed

- Schedule objects of the server read past an uninitialized string when
  they were named: a Who-Has by name from any device on the network, or a
  read of their Object_Name, made bacnet-stack's `Schedule_Object_Name`
  check the UTF-8 of stack memory past the string, with an uninitialized
  length (found by the native fuzzer).
- Remote clients could make the server allocate up to 2 GiB per File
  object (AtomicWriteFile at a large start position, File_Size writes).
  They now grow a file up to `maxSize` of `addFile`/`configureFile`
  (16 MiB by default) and all files together up to 256 MiB; the content
  set by the application is not limited (found by the native fuzzer).
- `BacnetBbmdClient` retries a request the UDP socket cannot send at once
  (`send` returns 0 on Windows while the previous datagram is on its way).

## [0.7.0] - not published separately (in 0.8.0)

Provisioning with Who-Am-I/You-Are, WriteGroup and Channel objects, COV
of several properties with one subscription. See *Migrating from 0.6.x*
in the README.

### Added

- **Who-Am-I / You-Are** (ASHRAE 135 clauses 16.11 and 16.12):
  `client.whoAmIRequests` and `client.sendYouAre` (broadcast, or to the
  requesting device with `destination: request.source`) assign device
  instances to new devices; `server.requestDeviceInstance` asks a
  supervisor for the instance of the server and applies it,
  `server.sendWhoAmI`, `server.youAreRequests` and
  `server.setDeviceInstance` (announced with an I-Am). `init` takes the
  `serialNumber` that identifies the server.
- **WriteGroup and Channel objects** (clause 15.11): `client.writeGroup`
  writes `BacnetGroupChannelValue`s to the channels of a control group;
  `server.addChannel` hosts Channel objects (channel number, control
  groups, members of the server) that write their members on WriteGroup or
  a write of their present value; `server.writeGroupEvents`.
- **SubscribeCOVPropertyMultiple** (clauses 13.16 and 13.17):
  `client.subscribeCOVPropertyMultiple` and
  `unsubscribeCOVPropertyMultiple` watch several properties of several
  objects (`BacnetCovSubscriptionSpecification`, `BacnetCovReference` with
  COV increment and timestamps) with one request; Confirmed and
  Unconfirmed COVNotificationMultiple arrive as one `CovNotificationEvent`
  per object with `notificationTime` and `changeTimes`.
  `BacnetProtocolException.firstFailedSubscription` names the subscription
  a device refused.
- **Typed properties**: `serialNumber`, `channelNumber` and
  `controlGroups`.
- **Testing**: `FakeBacnetClient.receive` delivers events such as
  `WhoAmIEvent`; fake clients record `sendYouAre` and `writeGroup`
  (`FakeBacnetRequest.arguments`) and take COV subscriptions of several
  properties.

## [0.6.0] - not published separately (in 0.8.0)

Schedules, calendars and trend logs on the server, backup and restore.
See *Migrating from 0.5.x* in the README.

### Added

- **Server — schedules and calendars**: `addSchedule` evaluates the
  exception schedule (dates, date ranges, week-n-days or calendars), the
  weekly schedule and the default within the effective period and writes
  its present value to objects of the server at its priority
  (`priorityForWriting`, `setPriorityForWriting`); `addCalendar`.
  `PropertyWriteEvent.internal` tells the writes of schedules from those
  of clients.
- **Server — trend logs**: `addTrendLog` records a property of an object
  of the server every `logInterval`, or the values the application
  records with `logValue`, in a buffer of `bufferSize` records (optionally
  stopping when full, between a start and stop time) and answers
  ReadRange by position, sequence number and time; clients enable it,
  purge it (Record_Count 0) and resize it.
- **Backup and restore** (ASHRAE 135 clause 19.1): `client.backupDevice`
  and `client.restoreDevice` (`BacnetDeviceBackups`) run the procedure and
  return a `BacnetDeviceBackup` that stores as JSON; `server.enableBackup`
  lets clients back up and restore the server, with `prepareBackup` and
  `applyRestore` callbacks of the application, and `server.backupState`.
  Constants `BacnetBackupState`.
- **Typed properties**: `schedulePresentValue`, `priorityForWriting`,
  `calendarPresentValue`, `configurationFiles`, `backupAndRestoreState`,
  `backupPreparationTime`, `restorePreparationTime`,
  `restoreCompletionTime`, `backupFailureTimeout` and `lastRestoreTime`.
- **Testing**: fake devices with `configurationFiles` take part in backup
  and restore (`backupState`, `restores`).

### Fixed

- Calendars of the server refused every Date_List write (bacnet-stack
  decodes it as an application value first).
- Exception_Schedule writes with a different number of special events were
  ignored by bacnet-stack.

## [0.5.0] - not published separately (in 0.8.0)

Device management, files and messages, routers and BBMDs, files on the
server. See *Migrating from 0.4.x* in the README.

### Added

- **Client — device management**: `deviceCommunicationControl`
  (`BacnetCommunicationState`), `reinitializeDevice`
  (`BacnetReinitializedState`), `createObject` (by type or identifier,
  with initial values) and `deleteObject`.
  `BacnetProtocolException.firstFailedElement` names the initial value or
  list element a device rejected (CreateObject, Add/RemoveListElement).
- **Client — files**: `readFileStream`/`writeFileStream` and
  `readFileRecords`/`writeFileRecords` (AtomicReadFile/AtomicWriteFile),
  and `readFile`/`writeFile` (`BacnetFileTransfer`) for whole files in
  chunks that fit into the device's maximum APDU (`deviceMaxApdu`), with
  progress and optional truncation.
- **Client — vendor services and messages**: `privateTransfer`
  (ConfirmedPrivateTransfer, returns the result block),
  `sendPrivateTransfer`, `textMessage` and `sendTextMessage`.
- **Client — routers and networks**: `networkMessages`
  (`NetworkMessageEvent` with a sealed `BacnetNetworkMessage`:
  I-Am-Router-To-Network, Network-Number-Is, Reject-Message-To-Network,
  Router-Busy/Available-To-Network, routing tables, ...) and
  `sendNetworkMessage`; `BacnetNetworkDiscovery` adds
  `whoIsRouterToNetwork`, `discoverRouters` (`BacnetRouter`),
  `whatIsNetworkNumber` and `readRoutingTable`. Constants
  `BacnetNetworkMessageType` and `BacnetNetworkRejectReason`.
- **BBMDs**: `BacnetBbmdClient` reads and writes the Broadcast
  Distribution Table (`BacnetBdtEntry`), reads the Foreign Device Table
  (`BacnetFdtEntry`) and deletes its entries, over an own UDP socket;
  refusals throw `BacnetBbmdException` (`BacnetBvlcResult`).
- **Server**: `init(password:)` and `setPassword` protect
  DeviceCommunicationControl and ReinitializeDevice;
  `communicationControls` (`CommunicationControlEvent`) and
  `reinitializeRequests` (`ReinitializeDeviceEvent`) report accepted
  requests.
- **Server — files**: `addFile` hosts File objects with the content in
  memory (AtomicReadFile, AtomicWriteFile, File_Size writes; appends
  answer with their position; Modification_Date and Archive follow the
  changes), `fileContent`, `setFileContent`, `configureFile` and
  `fileWrites` (`FileWriteEvent`).
- **Typed properties**: `fileType`, `fileSize`, `modificationDate`,
  `archive`, `readOnly` and `fileAccessMethod` (`BacnetFileAccessMethod`).
- **Testing**: fake devices simulate DeviceCommunicationControl (silent
  device, `password`), `reinitializations`, object creation and deletion,
  File objects (`addFile`, `fileContent`), `onPrivateTransfer` and
  received `messages`; `FakeBacnetRouter` and
  `FakeBacnetClient.networkNumber` simulate routers.

### Changed

- **Breaking, security**: the server accepted DeviceCommunicationControl
  and ReinitializeDevice with bacnet-stack's well-known default password
  "filister", so anyone on the network could silence it. Without a
  password set it now refuses both.
- **Breaking**: `CommunicationControlEvent`, `ReinitializeDeviceEvent`,
  `NetworkMessageEvent` and `FileWriteEvent` are new `BacnetEvent`
  subclasses; `BacnetClient` has new methods.

### Fixed

- Broadcasts to the local network (`sendWhoIs(network: 0)` and other
  unconfirmed services with `network: 0`) went as a unicast to the
  broadcast address: BBMDs did not forward them and a registered foreign
  device did not distribute them.
  They are Original-Broadcast-NPDUs (Distribute-Broadcast-To-Network as
  foreign device) now.

## [0.4.1] - 2026-10-01

### Fixed

- The published package builds: 0.4.0 lacked the BACnet/SC headers that
  `bacapp.h` includes (`.pubignore` excluded the whole `datalink/bsc`
  directory), so the build hook failed in applications.
  `tool/check_package.dart` now builds the package from the published
  files before a release.

## [0.4.0] - 2026-10-01

Alarm subscriptions and server alarm events. See *Migrating from 0.3.x*
in the README.

### Added

- **Client — subscriptions**: `client.subscribeAlarms(deviceId,
  notificationClass: n)` adds the client to the Recipient_List (with
  WriteProperty for devices without AddListElement) and returns an
  `AlarmSubscription` with its `notifications`, `eventInformation()`,
  `refresh()` and `cancel()`. `BacnetClient.localAddress()` returns the
  BACnet/IP address of the client. `BacnetEventSummary` lists its
  `unacknowledgedTransitions` with `timeStampOf` and `stateOf` for
  acknowledging them.
- **Server — events**: `alarmAcknowledgements`
  (`AlarmAcknowledgedEvent`) and `listElementEvents` (`ListElementEvent`,
  e.g. to persist Recipient_List changes).
- **Testing**: `FakeBacnetDevice.unsupportedServices` rejects services,
  to test the fallbacks of applications.
- **Example**: an alarms screen per device (subscription, active alarms,
  acknowledgement, notification log) with a widget test on
  `FakeBacnetClient`.

### Changed

- **Breaking**: `AlarmAcknowledgedEvent` and `ListElementEvent` are new
  subclasses of `BacnetEvent`; classes implementing `BacnetClient` need
  `localAddress()`.
- **Breaking**: `BacnetEventSummary.isUnacknowledged` is true when any
  transition waits for an acknowledgement (before: only the transition
  into the current event state, so an alarm that returned to normal
  unacknowledged counted as acknowledged).

### Fixed

- The package contains the bacnet-stack sources again: 0.1.0 to 0.3.0
  were uploaded without them, so the build hook failed in applications.

## [0.3.0] - 2026-10-01

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
