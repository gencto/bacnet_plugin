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
