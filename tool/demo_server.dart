// Starts a BACnet server with N analog values and alarm objects; used by
// tests and benchmarks.
// Usage: dart run tool/demo_server.dart [port] [deviceId] [objects]
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bacnet_plugin/bacnet_plugin.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 47811;
  final deviceId = args.length > 1 ? int.parse(args[1]) : 1001;
  final objects = args.length > 2 ? int.parse(args[2]) : 100;
  final iface = Platform.environment['BACNET_IFACE'] ?? 'lo';
  final server = BacnetServer(
    config: BacnetConfig(
      interface: iface,
      port: port,
      logLevel: BacnetLogLevel.warning,
      logger: const ConsoleBacnetLogger(),
    ),
  );
  await server.start();
  await server.init(
    deviceId,
    'DemoServer',
    vendorName: 'bacnet_plugin',
    modelName: 'Demo',
    serialNumber: 'DEMO-$deviceId',
    password: 'demo-password',
  );
  // listen before adding objects: events nobody listens to are lost, and
  // the schedule below writes its first value right away
  server.fileWrites.listen((e) => print('FILE $e'));
  server.writeEvents.listen((e) async {
    print('WRITE $e');
    if (e.objectType == BacnetObjectType.analogValue &&
        e.instance == 911 &&
        e.propertyId == BacnetPropertyId.presentValue &&
        e.value != null) {
      await server.logValue(
        2,
        e.value!,
        statusFlags: const BacnetStatusFlags(overridden: true),
      );
    }
  });
  server.alarmAcknowledgements.listen((e) => print('ACK $e'));
  server.listElementEvents.listen((e) => print('LIST $e'));
  server.communicationControls.listen((e) => print('DCC $e'));
  server.reinitializeRequests.listen((e) => print('REINIT $e'));
  server.writeGroupEvents.listen((e) => print('GROUP $e'));
  for (var i = 0; i < objects; i++) {
    await server.addObject(
      BacnetObjectType.analogValue,
      i,
      name: 'AV-$i',
      units: BacnetEngineeringUnits.degreesCelsius,
      covIncrement: 0.1,
      presentValue: BacnetReal(i.toDouble()),
    );
  }
  await server.addObject(BacnetObjectType.binaryValue, 0, name: 'BV-0');
  await server.addObject(
    BacnetObjectType.multiStateValue,
    0,
    name: 'MSV-0',
    stateTexts: ['Off', 'On', 'Auto'],
    presentValue: const BacnetUnsigned(1),
  );
  // alarms: Notification Class 1 with an analog value that leaves 10..30
  // and a binary value that alarms when active
  await server.addNotificationClass(1, name: 'Alarms');
  await server.addObject(
    BacnetObjectType.analogValue,
    objects,
    name: 'Alarm-AV',
    presentValue: const BacnetReal(20),
  );
  await server.enableEventReporting(
    BacnetObject(type: BacnetObjectType.analogValue, instance: objects),
    notificationClass: 1,
    highLimit: 30,
    lowLimit: 10,
    deadband: 1,
  );
  await server.addObject(BacnetObjectType.binaryValue, 1, name: 'Alarm-BV');
  await server.enableEventReporting(
    const BacnetObject(type: BacnetObjectType.binaryValue, instance: 1),
    notificationClass: 1,
    alarmValue: BacnetBinaryPV.active,
    notifyType: BacnetNotifyType.event,
  );
  // files kept in memory: a writable one and a read only one
  await server.addFile(
    1,
    name: 'notes.txt',
    description: 'Notes of the operator',
    fileType: 'text/plain',
    content: 'hello from the server'.codeUnits,
  );
  await server.addFile(
    2,
    name: 'firmware.bin',
    readOnly: true,
    content: List.generate(3000, (i) => i & 0xFF),
  );
  // a schedule writing AV 900 at priority 12, and a calendar it can refer
  // to in its exception schedule
  await server.addObject(
    BacnetObjectType.analogValue,
    900,
    name: 'Scheduled-AV',
    presentValue: const BacnetReal(0),
  );
  await server.addCalendar(1, name: 'Holidays');
  await server.addSchedule(
    1,
    name: 'Setpoint',
    scheduleDefault: const BacnetReal(5),
    weeklySchedule: BacnetWeeklySchedule([
      for (var day = 0; day < 7; day++)
        const [
          BacnetTimeValue(
            BacnetTime(hour: 0, minute: 0, second: 0, hundredths: 0),
            BacnetReal(20),
          ),
        ],
    ]),
    references: const [
      BacnetDeviceObjectPropertyReference(
        object: BacnetObject(type: BacnetObjectType.analogValue, instance: 900),
        property: BacnetPropertyId.presentValue,
      ),
    ],
    priorityForWriting: 12,
  );
  // trend logs: one polls AV 910 every second, the application records
  // the values clients write to AV 911 in the other
  await server.addObject(
    BacnetObjectType.analogValue,
    910,
    name: 'Logged-AV',
    presentValue: const BacnetReal(1),
  );
  await server.addObject(
    BacnetObjectType.analogValue,
    911,
    name: 'App-logged-AV',
    presentValue: const BacnetReal(0),
  );
  await server.addTrendLog(
    1,
    name: 'AV 910 log',
    source: const BacnetDeviceObjectPropertyReference(
      object: BacnetObject(type: BacnetObjectType.analogValue, instance: 910),
      property: BacnetPropertyId.presentValue,
    ),
    logInterval: const Duration(seconds: 1),
    bufferSize: 100,
  );
  await server.addTrendLog(2, name: 'AV 911 writes', bufferSize: 10);
  // backup and restore: the settings of the application in file 3
  var settings = 'setpoint=21';
  await server.addFile(3, name: 'settings.txt', fileType: 'text/plain');
  await server.enableBackup(
    files: [3],
    prepareBackup: () => server.setFileContent(3, settings.codeUnits),
    applyRestore: () async {
      settings = String.fromCharCodes(await server.fileContent(3));
      print('RESTORED $settings');
    },
  );
  // a Channel: WriteGroup of control group 5 with channel 7 writes AV 920
  await server.addObject(
    BacnetObjectType.analogValue,
    920,
    name: 'Group-AV',
    presentValue: const BacnetReal(0),
  );
  await server.addChannel(
    1,
    name: 'Lights',
    channelNumber: 7,
    controlGroups: [5],
    members: const [
      BacnetDeviceObjectPropertyReference(
        object: BacnetObject(type: BacnetObjectType.analogValue, instance: 920),
        property: BacnetPropertyId.presentValue,
      ),
    ],
  );
  // lighting and color objects
  await server.addLightingOutput(60, name: 'Desk lamp');
  await server.addColor(61, name: 'RGB strip');
  await server.addColorTemperature(62, name: 'Tunable white');
  // control and grouping objects
  await server.addLoop(1, name: 'PID loop');
  await server.addTimer(1, name: 'Egress timer');
  await server.addAccumulator(1, name: 'Energy meter');
  await server.addAveraging(1, name: 'Temp average');
  await server.addLoadControl(1, name: 'Load shed');
  await server.addStructuredView(1, name: 'Room view');
  // event enrollment: watches a dedicated analog value with OUT_OF_RANGE and
  // reports to its own notification class (2)
  await server.addNotificationClass(2, name: 'EE Alarms');
  await server.addObject(
    BacnetObjectType.analogValue,
    objects + 1,
    name: 'EE-source',
    presentValue: const BacnetReal(20),
  );
  await server.addEventEnrollment(
    1,
    monitored: BacnetObject(
      type: BacnetObjectType.analogValue,
      instance: objects + 1,
    ),
    notificationClass: 2,
    highLimit: 30,
    lowLimit: 10,
    deadband: 1,
    name: 'Range watch',
  );
  // auditing: an Audit Log and an Audit Reporter that records client writes
  // and sends an AuditNotification to the test client (port 47862)
  await server.addAuditLog(1, name: 'Audit log');
  await server.addAuditReporter(
    1,
    name: 'Write reporter',
    auditLog: 1,
    recipient: BacnetRecipient.ip('127.0.0.1', 47862),
  );
  // acts as the BACnet router to two virtual networks
  await server.enableRouting([100, 200]);
  // "provision <ip> <port>": asks the supervisor there for a device
  // instance (Who-Am-I / You-Are)
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) async {
    final words = line.trim().split(' ');
    if (words.length == 3 && words[0] == 'provision') {
      final port = int.parse(words[2]);
      final instance = await server.requestDeviceInstance(
        supervisor: BacnetAddressRecipient(
          network: 0,
          mac: [...words[1].split('.').map(int.parse), port >> 8, port & 0xFF],
        ),
        timeout: const Duration(seconds: 10),
        retryInterval: const Duration(seconds: 1),
      );
      print('PROVISIONED $instance');
    } else if (words.length == 2 &&
        words[0] == 'timemaster' &&
        words[1] == 'off') {
      await server.disableTimeMaster();
      print('TIMEMASTER off');
    } else if (words.length == 4 && words[0] == 'timemaster') {
      // "timemaster <interval_seconds> <local|utc> <ip:port>": sends a
      // (UTC)TimeSynchronization to that recipient at the interval
      final host = words[3].split(':');
      final port = int.parse(host[1]);
      await server.enableTimeMaster(
        interval: Duration(seconds: int.parse(words[1])),
        utc: words[2] == 'utc',
        recipients: [BacnetRecipient.ip(host[0], port)],
      );
      print('TIMEMASTER ${words[1]}s ${words[2]} to ${words[3]}');
    }
  });
  print('READY ${server.config.port} device $deviceId objects $objects');
  if (Platform.environment['BACNET_HEARTBEAT'] != null) {
    // diagnostic: prove the engine stays responsive and show the UDP counters
    Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final s = await server.stats();
        stderr.writeln(
          'HEARTBEAT rx=${s.packetsReceived} sent=${s.requestsSent} '
          'queued=${s.queuedRequests} inflight=${s.inFlightRequests} '
          'dropped=${s.repliesDropped}',
        );
      } on Object catch (e) {
        stderr.writeln('HEARTBEAT-ERR $e');
      }
    });
  }
  final random = Random(1);
  // keep values moving to exercise COV
  Timer.periodic(const Duration(milliseconds: 200), (_) async {
    await server.updatePresentValues([
      for (var i = 0; i < min(objects, 10); i++)
        BacnetPresentValueUpdate(
          objectType: BacnetObjectType.analogValue,
          instance: i,
          value: BacnetReal(i + random.nextDouble() * 10),
        ),
    ]);
  });
  await ProcessSignal.sigterm.watch().first;
  await server.close();
  exit(0);
}
