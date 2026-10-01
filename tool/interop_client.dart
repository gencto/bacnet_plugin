// Exercises the client against bacnet-stack's reference server (bacserv).
// Usage: dart run tool/interop_client.dart <port> <device>
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';

Future<void> main(List<String> args) async {
  final port = int.parse(args[0]);
  final device = int.parse(args[1]);
  final client = BacnetClient(
    config: const BacnetConfig(
      interface: 'lo',
      port: 47812,
      requestTimeout: Duration(seconds: 10),
      logLevel: BacnetLogLevel.warning,
      logger: ConsoleBacnetLogger(),
    ),
  );
  await client.start();
  await client.addDeviceBinding(device, '127.0.0.1', port: port);
  final scanner = DeviceScanner(client);
  final details = await scanner.getDeviceDetails(device);
  print(
    'details: $details model=${details.modelName} '
    'fw=${details.firmwareRevision} rev=${details.protocolRevision}',
  );
  final objects = await client.scanDevice(device);
  final types = <String, int>{};
  for (final o in objects) {
    final name = BacnetObjectType.getName(o.type);
    types[name] = (types[name] ?? 0) + 1;
  }
  print('objects ${objects.length}: $types');
  final scan = await scanner.scanDevice(
    device,
    propertyIds: const [
      BacnetPropertyId.objectName,
      BacnetPropertyId.presentValue,
      BacnetPropertyId.statusFlags,
    ],
    maxObjects: 1000,
  );
  final withValues = scan.values.where((p) => p.isNotEmpty).length;
  print('scanned ${scan.length} objects, $withValues with properties');
  final av = objects.firstWhere((o) => o.type == BacnetObjectType.analogValue);
  print(
    'AV ${av.instance} = ${await client.readProperty(device, av.type, av.instance, BacnetPropertyId.presentValue)}',
  );
  await client.writeProperty(
    device,
    av.type,
    av.instance,
    BacnetPropertyId.presentValue,
    const BacnetReal(33.25),
    priority: 9,
  );
  print(
    'AV after write = ${await client.readProperty(device, av.type, av.instance, BacnetPropertyId.presentValue)}',
  );
  await client.writeProperty(
    device,
    av.type,
    av.instance,
    BacnetPropertyId.presentValue,
    const BacnetNull(),
    priority: 9,
  );
  print(
    'AV after relinquish = ${await client.readProperty(device, av.type, av.instance, BacnetPropertyId.presentValue)}',
  );
  print(
    'local date/time: ${await client.readProperty(device, BacnetObjectType.device, device, BacnetPropertyId.localDate)} '
    '${await client.readProperty(device, BacnetObjectType.device, device, BacnetPropertyId.localTime)}',
  );
  final tl = objects.where((o) => o.type == BacnetObjectType.trendLog).toList();
  if (tl.isNotEmpty) {
    try {
      final log = await client.getTrendLog(device, tl.first.instance, count: 5);
      print(
        'trend log ${tl.first.instance}: $log ${log.entries.take(3).toList()}',
      );
    } on BacnetException catch (e) {
      print('trend log failed: $e');
    }
  }
  final covs = <CovNotificationEvent>[];
  final sub = client.covEvents.listen(covs.add);
  await client.subscribeCOV(
    device,
    av.type,
    av.instance,
    processId: 3,
    lifetime: const Duration(seconds: 30),
  );
  await client.writeProperty(
    device,
    av.type,
    av.instance,
    BacnetPropertyId.presentValue,
    const BacnetReal(50),
    priority: 9,
  );
  await Future<void>.delayed(const Duration(seconds: 2));
  print('cov: ${covs.length} ${covs.isEmpty ? '' : covs.last}');
  await client.unsubscribeCOV(device, av.type, av.instance, processId: 3);
  await sub.cancel();
  await client.writeProperty(
    device,
    av.type,
    av.instance,
    BacnetPropertyId.presentValue,
    const BacnetNull(),
    priority: 9,
  );
  try {
    await client.readProperty(
      device,
      BacnetObjectType.analogValue,
      4000000,
      BacnetPropertyId.presentValue,
    );
  } on BacnetProtocolException catch (e) {
    print('expected: $e');
  }
  try {
    await client.readProperty(
      4000001,
      BacnetObjectType.analogValue,
      1,
      BacnetPropertyId.presentValue,
      timeout: const Duration(seconds: 3),
    );
  } on BacnetException catch (e) {
    print('expected: $e');
  }
  // object names and status flags of every object, merged into
  // ReadPropertyMultiple and one by one
  final single = BacnetClient(
    config: client.config.copyWith(coalesceReads: false),
  );
  await single.start();
  for (final reader in [client, single]) {
    final before = (await client.stats()).requestsSent;
    final sw = Stopwatch()..start();
    final results = await Future.wait([
      for (final object in objects)
        for (final property in const [
          BacnetPropertyId.objectName,
          BacnetPropertyId.statusFlags,
        ])
          reader
              .readProperty(device, object.type, object.instance, property)
              .then<Object?>((v) => v, onError: (Object e) => e),
    ]);
    final requests = (await client.stats()).requestsSent - before;
    print(
      '${results.length} reads (coalesce: ${reader.config.coalesceReads}): '
      '${sw.elapsedMilliseconds} ms, $requests requests, '
      '${results.whereType<BacnetException>().length} errors',
    );
  }
  await single.close();
  await typedProperties(client, device, objects);
  await alarms(client, device, objects);
  await management(client, device, objects);
  await bbmd(client, port);
  print(await client.stats());
  await client.close();
  exit(0);
}

/// Reads the constructed properties of schedules, calendars and trend logs
/// as typed values and writes some of them back.
Future<void> typedProperties(
  BacnetClient client,
  int device,
  List<BacnetObject> objects,
) async {
  var failures = 0;
  Future<void> read<T>(BacnetObject object, BacnetProperty<T> property) async {
    try {
      final value = await client.read(device, object, property);
      print('typed ${object.type.label} ${property.id.label}: $value');
    } on BacnetProtocolException catch (e) {
      print(
        'typed ${object.type.label} ${property.id.label}: ${e.errorCode.label}',
      );
    } on BacnetDecodeException catch (e) {
      failures++;
      print('typed ${property.id.label} FAILED: $e');
    }
  }

  // writes [next], compares the read back value and restores the old one
  Future<void> roundTrip<T>(
    BacnetObject object,
    BacnetWritableProperty<T> property,
    T Function(T current) change,
    bool Function(T a, T b) equals,
  ) async {
    try {
      final before = await client.read(device, object, property);
      final next = change(before);
      await client.write(device, object, property, next);
      final after = await client.read(device, object, property);
      final ok = equals(after, next);
      if (!ok) failures++;
      print('typed write ${property.id.label}: ${ok ? 'same' : 'DIFFERENT'}');
      await client.write(device, object, property, before);
    } on BacnetProtocolException catch (e) {
      print('typed write ${property.id.label}: ${e.errorCode.label}');
    }
  }

  bool same(Object a, Object b) => a == b;
  bool sameList(List<Object> a, List<Object> b) =>
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((e) => e);
  BacnetObject? first(BacnetObjectType type) =>
      objects.where((o) => o.type == type).firstOrNull;
  const midnight = BacnetTime(hour: 0, minute: 0, second: 0, hundredths: 0);

  if (first(BacnetObjectType.schedule) case final schedule?) {
    await read(schedule, BacnetProperties.weeklySchedule);
    await read(schedule, BacnetProperties.exceptionSchedule);
    await read(schedule, BacnetProperties.effectivePeriod);
    await read(schedule, BacnetProperties.scheduleDefault);
    await read(schedule, BacnetProperties.listOfObjectPropertyReferences);
    await roundTrip(schedule, BacnetProperties.weeklySchedule, (s) {
      final days = [for (final day in s.days) List.of(day)];
      days[0] = [
        const BacnetTimeValue(midnight, BacnetReal(21)),
        const BacnetTimeValue(
          BacnetTime(hour: 18, minute: 30, second: 0, hundredths: 0),
          BacnetNull(),
        ),
      ];
      return BacnetWeeklySchedule(days);
    }, same);
    await roundTrip(schedule, BacnetProperties.exceptionSchedule, (events) {
      // replace entries: the array cannot grow beyond its size
      if (events.length < 3) return events;
      return [
        ...events.skip(3),
        BacnetSpecialEvent(
          period: const BacnetCalendarDate(
            BacnetDate(year: 2026, month: 12, day: 25, weekday: 5),
          ),
          timeValues: const [BacnetTimeValue(midnight, BacnetReal(16))],
          priority: 10,
        ),
        BacnetSpecialEvent(
          period: const BacnetCalendarDateRange(
            BacnetDateRange(
              BacnetDate(year: 2026, month: 7, day: 1),
              BacnetDate(year: 2026, month: 7, day: 31),
            ),
          ),
          timeValues: const [],
          priority: 3,
        ),
        BacnetSpecialEvent(
          period: const BacnetCalendarWeekNDay(BacnetWeekNDay(dayOfWeek: 7)),
          timeValues: const [],
          priority: 16,
        ),
      ];
    }, sameList);
    await roundTrip(
      schedule,
      BacnetProperties.effectivePeriod,
      (_) => const BacnetDateRange(
        BacnetDate(year: 2026, month: 1, day: 1),
        BacnetDate(year: 2026, month: 12, day: 31),
      ),
      same,
    );
  }
  if (first(BacnetObjectType.calendar) case final calendar?) {
    await read(calendar, BacnetProperties.dateList);
  }
  if (first(BacnetObjectType.trendLog) case final log?) {
    await read(log, BacnetProperties.enable);
    await read(log, BacnetProperties.startTime);
    await read(log, BacnetProperties.stopTime);
    await read(log, BacnetProperties.logDeviceObjectProperty);
    await read(log, BacnetProperties.recordCount);
    await roundTrip(
      log,
      BacnetProperties.startTime,
      (_) => BacnetDateTime.fromDateTime(DateTime(2026, 10, 1, 8)),
      same,
    );
  }
  if (first(BacnetObjectType.analogInput) case final input?) {
    await read(input, BacnetProperties.eventTimeStamps);
    await read(input, BacnetProperties.ackedTransitions);
    await read(input, BacnetProperties.limitEnable);
  }
  if (first(BacnetObjectType.analogOutput) case final output?) {
    await read(output, BacnetProperties.priorityArray);
  }
  print('typed decode failures: $failures');
}

/// Subscribes to the Notification Class of an Analog Value, drives it out
/// of its limits and back, and acknowledges the alarm.
Future<void> alarms(
  BacnetClient client,
  int device,
  List<BacnetObject> objects,
) async {
  final av = objects.firstWhere((o) => o.type == BacnetObjectType.analogValue);
  final nc = objects.firstWhere(
    (o) => o.type == BacnetObjectType.notificationClass,
  );
  final me = BacnetDestination(
    recipient: BacnetRecipient.ip('127.0.0.1', client.config.port),
    processId: 5,
  );
  final before = await client.read(device, nc, BacnetProperties.recipientList);
  try {
    await client.addListElements(device, nc, BacnetProperties.recipientList, [
      me,
    ]);
  } on BacnetRejectException catch (e) {
    // bacserv does not implement AddListElement: write the whole list
    print('AddListElement: $e');
    await client.write(device, nc, BacnetProperties.recipientList, [
      ...before,
      me,
    ]);
  }
  print(
    'recipients ${await client.read(device, nc, BacnetProperties.recipientList)}',
  );
  await client.write(
    device,
    nc,
    BacnetProperties.ackRequired,
    const BacnetEventTransitionBits(toOffNormal: true),
  );
  print('priority ${await client.read(device, nc, BacnetProperties.priority)}');
  await client.write(
    device,
    av,
    BacnetProperties.notificationClass,
    nc.instance,
  );
  await client.write(device, av, BacnetProperties.highLimit, 50);
  await client.write(device, av, BacnetProperties.lowLimit, 0);
  await client.write(device, av, BacnetProperties.deadband, 1);
  await client.write(device, av, BacnetProperties.timeDelay, 0);
  await client.write(
    device,
    av,
    BacnetProperties.limitEnable,
    const BacnetLimitEnable(lowLimit: true, highLimit: true),
  );
  await client.write(
    device,
    av,
    BacnetProperties.eventEnable,
    const BacnetEventTransitionBits(
      toOffNormal: true,
      toFault: true,
      toNormal: true,
    ),
  );

  Future<EventNotificationEvent> next(BacnetEventState state) => client
      .eventNotifications
      .firstWhere((e) => e.object == av && e.toState == state)
      .timeout(const Duration(seconds: 10));

  final alarmReceived = next(BacnetEventState.highLimit);
  await client.write(
    device,
    av,
    BacnetProperties.analogPresentValue,
    60,
    priority: 8,
  );
  final alarm = await alarmReceived;
  print('alarm $alarm');
  print('event information ${await client.getEventInformation(device)}');
  print('alarm summary ${await client.getAlarmSummary(device)}');
  final acked = client.eventNotifications
      .firstWhere((e) => e.object == av && e.isAckNotification)
      .timeout(const Duration(seconds: 10));
  await client.acknowledgeEvent(alarm, source: 'interop');
  print('ack notification ${await acked}');
  final normalReceived = next(BacnetEventState.normal);
  await client.write(
    device,
    av,
    BacnetProperties.analogPresentValue,
    20,
    priority: 8,
  );
  print('normal ${await normalReceived}');
  await client.writeProperty(
    device,
    av.type,
    av.instance,
    BacnetPropertyId.presentValue,
    const BacnetNull(),
    priority: 8,
  );
  try {
    await client.removeListElements(
      device,
      nc,
      BacnetProperties.recipientList,
      [me],
    );
  } on BacnetRejectException {
    await client.write(device, nc, BacnetProperties.recipientList, before);
  }
  print(
    'recipients ${await client.read(device, nc, BacnetProperties.recipientList)}',
  );
  print('alarms: ok');
}

/// DeviceCommunicationControl, ReinitializeDevice, Create/DeleteObject and
/// file transfers (bacserv's password is "filister").
Future<void> management(
  BacnetClient client,
  int device,
  List<BacnetObject> objects,
) async {
  Future<void> expectError(String what, Future<void> request) async {
    try {
      await request;
      print('$what: FAIL (no error)');
    } on BacnetException catch (e) {
      print('$what: $e');
    }
  }

  await expectError(
    'DCC without password',
    client.deviceCommunicationControl(
      device,
      BacnetCommunicationState.disableInitiation,
    ),
  );
  await client.deviceCommunicationControl(
    device,
    BacnetCommunicationState.disableInitiation,
    duration: const Duration(minutes: 1),
    password: 'filister',
  );
  print(
    'DCC disable initiation: name '
    '${await client.read(device, BacnetObject(type: BacnetObjectType.device, instance: device), BacnetProperties.objectName)}',
  );
  await client.deviceCommunicationControl(
    device,
    BacnetCommunicationState.enable,
    password: 'filister',
  );
  await expectError(
    'reinitialize with wrong password',
    client.reinitializeDevice(
      device,
      BacnetReinitializedState.warmStart,
      password: 'wrong',
    ),
  );
  await client.reinitializeDevice(
    device,
    BacnetReinitializedState.activateChanges,
    password: 'filister',
  );
  print('reinitialize activate changes: ok');

  // bacnet-stack does not accept Object_Name as initial value
  await expectError(
    'create with Object_Name',
    client.createObject(
      device,
      type: BacnetObjectType.analogValue,
      initialValues: const [
        BacnetPropertyValue(
          propertyIdentifier: BacnetPropertyId.objectName,
          value: BacnetCharacterString('Created by interop'),
        ),
      ],
    ),
  );
  final created = await client.createObject(
    device,
    type: BacnetObjectType.analogValue,
    initialValues: const [
      BacnetPropertyValue(
        propertyIdentifier: BacnetPropertyId.presentValue,
        value: BacnetReal(42),
      ),
    ],
  );
  print(
    'created $created: '
    '${await client.read(device, created, BacnetProperties.objectName)} = '
    '${await client.read(device, created, BacnetProperties.analogPresentValue)}',
  );
  await expectError(
    'create existing',
    client.createObject(device, object: created),
  );
  await client.deleteObject(device, created);
  await expectError(
    'read deleted',
    client.readProperty(
      device,
      created.type,
      created.instance,
      BacnetPropertyId.objectName,
    ),
  );

  final file = objects.firstWhere((o) => o.type == BacnetObjectType.file);
  final content = List.generate(4000, (i) => (i * 13) & 0xFF);
  // bacnet-stack writes File_Size only with a callback bacserv lacks
  await expectError(
    'truncate',
    client.writeProperty(
      device,
      BacnetObjectType.file,
      file.instance,
      BacnetPropertyId.fileSize,
      const BacnetUnsigned(0),
    ),
  );
  await client.writeFile(device, file.instance, content);
  final read = await client.readFile(
    device,
    file.instance,
    onProgress: (done, total) => print('read $done / $total'),
  );
  var same = read.length >= content.length;
  for (var i = 0; same && i < content.length; i++) {
    same = read[i] == content[i];
  }
  print('file round trip ${read.length} octets: ${same ? 'ok' : 'FAIL'}');
  await expectError(
    'record access',
    client.readFileRecords(device, file.instance, start: 0, count: 1),
  );
  print('management: ok');
}

/// Reads and changes the tables of bacserv as BBMD (BBMD enabled by
/// default in bacnet-stack builds; BACNET_BDT_ADDR_2 adds a peer).
Future<void> bbmd(BacnetClient client, int port) async {
  final bbmd = BacnetBbmdClient('127.0.0.1', port: port);
  print('BDT: ${await bbmd.readBroadcastDistributionTable()}');
  await client.registerForeignDevice('127.0.0.1', port: port, ttl: 60);
  List<BacnetFdtEntry> fdt = const [];
  for (var i = 0; i < 20 && fdt.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    fdt = await bbmd.readForeignDeviceTable();
  }
  print('FDT after registration: $fdt');
  final me = await client.localAddress();
  await bbmd.deleteForeignDeviceTableEntry(me.ipAddress!, port: me.port!);
  print('FDT after delete: ${await bbmd.readForeignDeviceTable()}');
  try {
    await bbmd.deleteForeignDeviceTableEntry('127.0.0.1', port: 1);
    print('delete of an unknown entry: accepted');
  } on BacnetBbmdException catch (e) {
    print('delete of an unknown entry: ${e.result.label}');
  }
  final table = await bbmd.readBroadcastDistributionTable();
  try {
    await bbmd.writeBroadcastDistributionTable([
      ...table,
      BacnetBdtEntry('127.0.0.1', port: 47899, mask: '255.255.255.0'),
    ]);
    print('BDT after write: ${await bbmd.readBroadcastDistributionTable()}');
    await bbmd.writeBroadcastDistributionTable(table);
  } on BacnetBbmdException catch (e) {
    print('Write-BDT refused: ${e.result.label}');
  }
}
