/// @docImport '../client/bacnet_client.dart';
/// @docImport '../constants/enumerations.dart';
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../codec/requests.dart';
import '../codec/value_encoding.dart';
import '../codec/writer.dart';
import '../constants/engineering_units.dart';
import '../constants/enumerations.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../constants/services.dart';
import '../core/bacnet_config.dart';
import '../core/exceptions.dart';
import '../core/logger.dart';
import '../core/types.dart';
import '../models/alarms.dart';
import '../models/audit.dart';
import '../models/bacnet_property.dart';
import '../models/bacnet_value.dart';
import '../models/complex_values.dart';
import '../models/events.dart';
import '../native/bacnet_system.dart';
import '../native/protocol.dart';
import 'server_state.dart';

/// One present value update for [BacnetServer.updatePresentValues].
@immutable
class BacnetPresentValueUpdate {
  /// Creates an update. [value] is a number ([BacnetReal], [BacnetDouble],
  /// [BacnetUnsigned], [BacnetSigned], [BacnetEnumerated]), a
  /// [BacnetBoolean] or a [BacnetNull] to relinquish [priority] of
  /// commandable objects.
  const BacnetPresentValueUpdate({
    required this.objectType,
    required this.instance,
    required this.value,
    this.priority = 16,
  });

  /// Object type.
  final BacnetObjectType objectType;

  /// Object instance.
  final int instance;

  /// New present value.
  final BacnetValue value;

  /// Priority for commandable objects (1..16).
  final int priority;
}

/// BACnetArrayAll: refers to a whole property rather than one array element.
const _arrayAll = 0xFFFFFFFF;

/// BACnet server hosting objects and answering client requests.
///
/// Read/write/COV requests from the network are answered entirely by the
/// native stack in the worker isolate (no Dart code runs per request), so a
/// server keeps up with many clients. Values are pushed from Dart with
/// [setPresentValue] or, for many points at once, [updatePresentValues].
///
/// ```dart
/// final server = BacnetServer(config: const BacnetConfig(interface: 'eth0'));
/// await server.start();
/// await server.init(4194300, 'Flutter BACnet Server');
/// await server.addObject(BacnetObjectType.analogInput, 1,
///     name: 'Supply Air Temp',
///     units: BacnetEngineeringUnits.degreesCelsius, covIncrement: 0.1);
/// await server.setPresentValue(
///     BacnetObjectType.analogInput, 1, const BacnetReal(21.5));
///
/// server.writeEvents.listen((event) {
///   print('${event.objectType}:${event.instance} <- ${event.value}');
/// });
/// ```
class BacnetServer {
  /// Creates a BACnet server.
  ///
  /// [logger] overrides [BacnetConfig.logger].
  BacnetServer({BacnetLogger? logger, BacnetConfig? config})
    : _config = config ?? const BacnetConfig() {
    if (logger != null) {
      _system.setLogger(logger);
    }
  }

  final BacnetConfig _config;
  final BacnetSystem _system = BacnetSystem.instance;

  /// The objects created with [addObject] (and its helpers), keyed by
  /// (object type, instance), for [captureState].
  final Map<(int, int), BacnetObjectState> _hosted = {};
  bool _started = false;
  int? _deviceId;
  StreamSubscription<ReinitializeDeviceEvent>? _backupRequests;

  /// Configuration of this server.
  BacnetConfig get config => _config;

  /// Writes performed by remote clients on objects of this server.
  Stream<PropertyWriteEvent> get writeEvents => _system.events
      .where((e) => e is PropertyWriteEvent)
      .cast<PropertyWriteEvent>();

  /// Accepted DeviceCommunicationControl requests of remote clients.
  Stream<CommunicationControlEvent> get communicationControls => _system.events
      .where((e) => e is CommunicationControlEvent)
      .cast<CommunicationControlEvent>();

  /// Accepted ReinitializeDevice requests of remote clients: restart or
  /// run the backup or restore procedure when they arrive.
  ///
  /// ```dart
  /// server.reinitializeRequests.listen((request) async {
  ///   if (request.state == BacnetReinitializedState.warmStart) {
  ///     await restartApplication();
  ///   }
  /// });
  /// ```
  Stream<ReinitializeDeviceEvent> get reinitializeRequests => _system.events
      .where((e) => e is ReinitializeDeviceEvent)
      .cast<ReinitializeDeviceEvent>();

  /// Sets the password remote DeviceCommunicationControl and
  /// ReinitializeDevice requests must carry (up to 20 characters); null
  /// refuses both.
  Future<void> setPassword(String? password) {
    _checkPassword(password);
    return _system.call<void>((id) => SetPasswordCommand(id, password));
  }

  static void _checkPassword(String? password) {
    if (password != null && (password.isEmpty || password.runes.length > 20)) {
      throw ArgumentError.value(
        password,
        'password',
        'must have 1 to 20 characters',
      );
    }
  }

  /// Alarm acknowledgements of remote clients (AcknowledgeAlarm).
  Stream<AlarmAcknowledgedEvent> get alarmAcknowledgements => _system.events
      .where((e) => e is AlarmAcknowledgedEvent)
      .cast<AlarmAcknowledgedEvent>();

  /// Changes of list properties by remote clients (Add/RemoveListElement),
  /// e.g. clients subscribing to the alarms of a Notification Class.
  Stream<ListElementEvent> get listElementEvents => _system.events
      .where((e) => e is ListElementEvent)
      .cast<ListElementEvent>();

  /// You-Are requests of supervisors: the device instance assigned to the
  /// device with a vendor, model name and serial number (see
  /// [requestDeviceInstance]).
  Stream<YouAreEvent> get youAreRequests =>
      _system.events.where((e) => e is YouAreEvent).cast<YouAreEvent>();

  /// WriteGroup requests received by this server; the Channel objects of
  /// [addChannel] in the group already wrote their members.
  Stream<WriteGroupEvent> get writeGroupEvents =>
      _system.events.where((e) => e is WriteGroupEvent).cast<WriteGroupEvent>();

  /// Writes of remote clients to the File objects of [addFile]
  /// (AtomicWriteFile). Changes of the size (writes of File_Size) arrive as
  /// [writeEvents].
  Stream<FileWriteEvent> get fileWrites =>
      _system.events.where((e) => e is FileWriteEvent).cast<FileWriteEvent>();

  /// Starts the BACnet stack (shared with [BacnetClient] instances).
  Future<void> start({String? interface, int? port}) async {
    if (_started) return;
    await _system.start(_config.copyWith(interface: interface, port: port));
    _started = true;
  }

  /// Initializes the local Device object and starts answering requests
  /// (Who-Is, Read/WriteProperty(Multiple), SubscribeCOV(Property),
  /// ReadRange, Add/RemoveListElement, AcknowledgeAlarm,
  /// GetEventInformation, GetAlarmSummary, AtomicReadFile, AtomicWriteFile,
  /// DeviceCommunicationControl, ReinitializeDevice and time
  /// synchronization). Sends an I-Am.
  ///
  /// DeviceCommunicationControl and ReinitializeDevice require [password]
  /// (up to 20 characters); without one the server refuses them with a
  /// password failure. See [communicationControls] and
  /// [reinitializeRequests].
  ///
  /// ```dart
  /// await server.init(4194300, 'Building Controller', vendorName: 'ACME');
  /// ```
  Future<void> init(
    int deviceId,
    String deviceName, {
    int? vendorId,
    String? vendorName,
    String? modelName,
    String? description,
    String? location,
    String? firmwareRevision,
    String? applicationSoftwareVersion,
    String? serialNumber,
    String? password,
  }) async {
    _checkPassword(password);
    await _system.call<void>(
      (id) => ServerEnableCommand(
        id,
        deviceId: deviceId,
        deviceName: deviceName,
        vendorId: vendorId,
        password: password,
        strings: {
          BacnetPropertyId.vendorName: ?vendorName,
          BacnetPropertyId.modelName: ?modelName,
          BacnetPropertyId.description: ?description,
          BacnetPropertyId.location: ?location,
          BacnetPropertyId.firmwareRevision: ?firmwareRevision,
          BacnetPropertyId.applicationSoftwareVersion:
              ?applicationSoftwareVersion,
          BacnetPropertyId.serialNumber: ?serialNumber,
        },
      ),
    );
    _deviceId = deviceId;
  }

  /// Adds an object to the server and returns its instance.
  ///
  /// Supported types: Analog/Binary/Multi-state Input/Output/Value, Integer
  /// Value, Positive Integer Value, CharacterString Value, Notification
  /// Class (see [addNotificationClass]) and every other object type of
  /// bacnet-stack that supports CreateObject.
  /// [stateTexts] defines the states of multi-state objects. See
  /// [setPresentValue] for the supported [presentValue]s.
  Future<int> addObject(
    BacnetObjectType objectType,
    int instance, {
    String? name,
    String? description,
    BacnetEngineeringUnits? units,
    double? covIncrement,
    bool? outOfService,
    List<String>? stateTexts,
    BacnetValue? presentValue,
  }) async {
    final created = await _system.call<int>(
      (id) => CreateObjectCommand(
        id,
        objectType: objectType,
        instance: instance,
        name: name,
        description: description,
        stateTexts: stateTexts,
        numbers: {
          if (units != null) BacnetPropertyId.units: units.toDouble(),
          BacnetPropertyId.covIncrement: ?covIncrement,
          if (outOfService != null)
            BacnetPropertyId.outOfService: outOfService ? 1 : 0,
        },
        presentValue: switch (presentValue) {
          null || BacnetCharacterString() => null,
          final value => _number(value),
        },
        presentValueString: presentValue?.asString,
      ),
    );
    _hosted[(objectType.value, created)] = BacnetObjectState(
      type: objectType,
      instance: created,
      name: name,
      description: description,
    );
    return created;
  }

  /// Adds a File object whose content the server keeps in memory and
  /// returns its instance: remote clients read it with AtomicReadFile
  /// (stream access) and, unless [readOnly], write it with AtomicWriteFile
  /// ([fileWrites]) and change its size by writing File_Size, up to
  /// [maxSize] octets (and while all files take less than 256 MiB);
  /// [content] and [setFileContent] are not limited.
  ///
  /// ```dart
  /// await server.addFile(
  ///   1,
  ///   name: 'settings.json',
  ///   fileType: 'application/json',
  ///   content: utf8.encode(jsonEncode(settings)),
  /// );
  /// server.fileWrites.listen((write) async {
  ///   final content = await server.fileContent(write.instance);
  ///   applySettings(jsonDecode(utf8.decode(content)));
  /// });
  /// ```
  Future<int> addFile(
    int instance, {
    List<int> content = const [],
    String? name,
    String? description,
    String fileType = 'application/octet-stream',
    bool readOnly = false,
    int maxSize = 16 * 1024 * 1024,
  }) async {
    final created = await addObject(
      BacnetObjectType.file,
      instance,
      name: name,
      description: description,
    );
    await configureFile(
      created,
      fileType: fileType,
      readOnly: readOnly,
      maxSize: maxSize,
    );
    if (content.isNotEmpty) await setFileContent(created, content);
    return created;
  }

  /// Sets the File_Type (a media type), Read_Only and the size up to which
  /// remote clients may grow a File object of [addFile] ([maxSize], at most
  /// 2^31 - 1 octets); null keeps the value.
  Future<void> configureFile(
    int instance, {
    String? fileType,
    bool? readOnly,
    int? maxSize,
  }) {
    if (maxSize != null) {
      RangeError.checkValueInInterval(maxSize, 0, 0x7FFFFFFF, 'maxSize');
    }
    return _system.call<void>(
      (id) => ConfigureFileCommand(
        id,
        instance,
        fileType: fileType,
        readOnly: readOnly,
        maxSize: maxSize,
      ),
    );
  }

  /// The content of File object [instance] of [addFile].
  Future<Uint8List> fileContent(int instance) =>
      _system.call<Uint8List>((id) => FileContentCommand(id, instance));

  /// Replaces the content of File object [instance] of [addFile] (also of
  /// a read only one: Read_Only applies to remote clients).
  Future<void> setFileContent(int instance, List<int> content) =>
      _system.call<void>(
        (id) =>
            SetFileContentCommand(id, instance, Uint8List.fromList(content)),
      );

  /// Removes an object from the server.
  Future<void> removeObject(BacnetObjectType objectType, int instance) {
    _hosted.remove((objectType.value, instance));
    return _system.call<void>(
      (id) => DeleteObjectCommand(id, objectType, instance),
    );
  }

  // ---- state persistence ----------------------------------------------------

  /// Captures the objects this server hosts (added with [addObject] and its
  /// helpers) and their current present values into a [BacnetServerState].
  ///
  /// Objects created by remote clients (CreateObject) are not included, and
  /// only the object identity, name, description and present value are
  /// captured — re-apply richer per-object configuration (units, limits,
  /// schedules, recipients) from the application after [restoreState].
  Future<BacnetServerState> captureState() async {
    final objects = <BacnetObjectState>[];
    for (final hosted in _hosted.values) {
      BacnetValue? value;
      try {
        value = await readProperty(
          hosted.type,
          hosted.instance,
          BacnetPropertyId.presentValue,
        );
      } on BacnetException {
        value = null; // objects without a present value
      }
      objects.add(
        BacnetObjectState(
          type: hosted.type,
          instance: hosted.instance,
          name: hosted.name,
          description: hosted.description,
          presentValue: value,
        ),
      );
    }
    return BacnetServerState(objects: objects, deviceInstance: _deviceId);
  }

  /// Captures the server state with [captureState] and persists it with
  /// [store] (e.g. a [JsonFileServerStateStore]).
  Future<void> saveState(BacnetServerStateStore store) async =>
      store.save(await captureState());

  /// Loads a snapshot from [store] and re-creates its objects and present
  /// values on this server. Does nothing when [store] holds no snapshot.
  /// Returns true when a snapshot was applied.
  Future<bool> restoreState(BacnetServerStateStore store) async {
    final state = await store.load();
    if (state == null) {
      return false;
    }
    await applyState(state);
    return true;
  }

  /// Re-creates the objects and present values of [state] on this server
  /// (used by [restoreState]).
  Future<void> applyState(BacnetServerState state) async {
    for (final object in state.objects) {
      await addObject(
        object.type,
        object.instance,
        name: object.name,
        description: object.description,
      );
      // setPresentValue only accepts scalar datatypes; complex present values
      // (and relinquished nulls) are left for the application to re-apply.
      final value = object.presentValue;
      final settable =
          value is BacnetReal ||
          value is BacnetDouble ||
          value is BacnetUnsigned ||
          value is BacnetSigned ||
          value is BacnetEnumerated ||
          value is BacnetBoolean ||
          value is BacnetCharacterString;
      if (value != null && settable) {
        try {
          await setPresentValue(object.type, object.instance, value);
        } on BacnetException {
          // the object has no writable present value: keep it unset
        }
      }
    }
  }

  /// Sets the present value of an object (local update, triggers COV
  /// notifications to subscribers).
  ///
  /// [value] is a number ([BacnetReal], [BacnetDouble], [BacnetUnsigned],
  /// [BacnetSigned], [BacnetEnumerated]), a [BacnetBoolean] (binary
  /// objects), a [BacnetCharacterString] (CharacterString Value) or a
  /// [BacnetNull] to relinquish [priority] of commandable objects. Other
  /// datatypes throw an [ArgumentError]; use [setProperty] for them.
  ///
  /// ```dart
  /// await server.setPresentValue(
  ///     BacnetObjectType.analogValue, 1, const BacnetReal(21.5));
  /// await server.setPresentValue(BacnetObjectType.binaryValue, 1,
  ///     const BacnetEnumerated(BacnetBinaryPV.active));
  /// ```
  Future<void> setPresentValue(
    BacnetObjectType objectType,
    int instance,
    BacnetValue value, {
    int priority = 16,
  }) {
    if (value case BacnetCharacterString(:final value)) {
      return _system.call<void>(
        (id) => SetTextCommand(
          id,
          objectType: objectType,
          instance: instance,
          propertyId: BacnetPropertyId.presentValue,
          value: value,
        ),
      );
    }
    return _system.call<void>(
      (id) => SetNumberCommand(
        id,
        objectType: objectType,
        instance: instance,
        propertyId: BacnetPropertyId.presentValue,
        value: _number(value),
        priority: priority,
      ),
    );
  }

  /// Applies many present value updates in one native call and returns the
  /// number of applied updates. Use it to feed thousands of points per
  /// second from a data source.
  Future<int> updatePresentValues(Iterable<BacnetPresentValueUpdate> updates) {
    final list = updates.toList(growable: false);
    if (list.isEmpty) return Future.value(0);
    final packed = ByteData(list.length * 16);
    for (var i = 0; i < list.length; i++) {
      final update = list[i];
      final at = i * 16;
      packed
        ..setUint32(at, update.instance, Endian.host)
        ..setUint16(at + 4, update.objectType, Endian.host)
        ..setUint8(at + 6, update.priority)
        ..setFloat64(at + 8, _number(update.value), Endian.host);
    }
    final transferable = TransferableTypedData.fromList([
      packed.buffer.asUint8List(),
    ]);
    return _system.call<int>(
      (id) => SetPresentValuesCommand(id, transferable, list.length),
    );
  }

  /// Sets out-of-service of an object.
  Future<void> setOutOfService(
    BacnetObjectType objectType,
    int instance,
    bool value,
  ) => _system.call<void>(
    (id) => SetNumberCommand(
      id,
      objectType: objectType,
      instance: instance,
      propertyId: BacnetPropertyId.outOfService,
      value: value ? 1 : 0,
    ),
  );

  /// Sets the object name.
  Future<void> setObjectName(
    BacnetObjectType objectType,
    int instance,
    String name,
  ) => _system.call<void>(
    (id) => SetTextCommand(
      id,
      objectType: objectType,
      instance: instance,
      propertyId: BacnetPropertyId.objectName,
      value: name,
    ),
  );

  /// Writes any property of a local object with WriteProperty semantics
  /// (the same checks as a remote write, no write notification).
  ///
  /// ```dart
  /// await server.setProperty(BacnetObjectType.analogValue, 1,
  ///     BacnetPropertyId.highLimit, const BacnetReal(28));
  /// ```
  Future<void> setProperty(
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId,
    BacnetValue value, {
    int priority = 16,
    int arrayIndex = -1,
  }) {
    final writer = BacnetWriter();
    encodeApplicationValue(writer, value);
    final payload = writer.toBytes();
    return _system.call<void>(
      (id) => LocalWriteCommand(
        id,
        objectType: objectType,
        instance: instance,
        propertyId: propertyId,
        payload: payload,
        arrayIndex: arrayIndex,
        priority: priority,
      ),
    );
  }

  /// Reads a property of a local object (see [BacnetClient.readProperty]
  /// for the returned values).
  Future<BacnetValue> readProperty(
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId, {
    int arrayIndex = -1,
  }) {
    return _system.call<BacnetValue>(
      (id) => LocalReadCommand(
        id,
        objectType: objectType,
        instance: instance,
        propertyId: propertyId,
        arrayIndex: arrayIndex,
      ),
    );
  }

  /// Reads [property] of a local object as its Dart type (see
  /// [BacnetClient.read]).
  Future<T> read<T>(BacnetObject object, BacnetProperty<T> property) =>
      readProperty(
        object.type,
        object.instance,
        property.id,
      ).then(property.decode);

  /// Writes [value] to [property] of a local object with WriteProperty
  /// semantics (see [setProperty]).
  Future<void> write<T>(
    BacnetObject object,
    BacnetWritableProperty<T> property,
    T value, {
    int priority = 16,
  }) => Future.sync(
    () => setProperty(
      object.type,
      object.instance,
      property.id,
      property.encodeValue(value),
      priority: priority,
    ),
  );

  // ---- schedules and calendars ---------------------------------------------

  /// Adds a Schedule object and returns its instance.
  ///
  /// Every 100 ms the server evaluates [exceptionSchedule] (dates, date
  /// ranges, week-n-days or Calendar objects of this server, see
  /// [addCalendar]), then [weeklySchedule], else [scheduleDefault], within
  /// [effectivePeriod], and writes a changed present value to [references]
  /// (properties of objects of this server) at [priorityForWriting]. Those
  /// writes arrive as [writeEvents] with `internal` set. Clients change the
  /// schedule with WriteProperty ([writeEvents]).
  ///
  /// ```dart
  /// const workday = [
  ///   BacnetTimeValue(
  ///     BacnetTime(hour: 7, minute: 0, second: 0, hundredths: 0),
  ///     BacnetReal(21),
  ///   ),
  ///   BacnetTimeValue(
  ///     BacnetTime(hour: 18, minute: 0, second: 0, hundredths: 0),
  ///     BacnetReal(17),
  ///   ),
  /// ];
  /// await server.addSchedule(
  ///   1,
  ///   name: 'Heating',
  ///   scheduleDefault: const BacnetReal(17),
  ///   // Monday to Friday, nothing at the weekend
  ///   weeklySchedule: BacnetWeeklySchedule([
  ///     for (var day = 0; day < 5; day++) workday,
  ///     const [],
  ///     const [],
  ///   ]),
  ///   references: [
  ///     BacnetDeviceObjectPropertyReference(
  ///       object: const BacnetObject(
  ///         type: BacnetObjectType.analogValue,
  ///         instance: 1,
  ///       ),
  ///       property: BacnetPropertyId.presentValue,
  ///     ),
  ///   ],
  ///   priorityForWriting: 12,
  /// );
  /// ```
  Future<int> addSchedule(
    int instance, {
    String? name,
    String? description,
    BacnetValue? scheduleDefault,
    BacnetWeeklySchedule? weeklySchedule,
    List<BacnetSpecialEvent> exceptionSchedule = const [],
    BacnetDateRange? effectivePeriod,
    List<BacnetDeviceObjectPropertyReference> references = const [],
    int priorityForWriting = 16,
  }) async {
    RangeError.checkValueInInterval(
      priorityForWriting,
      1,
      16,
      'priorityForWriting',
    );
    final created = await addObject(
      BacnetObjectType.schedule,
      instance,
      name: name,
      description: description,
    );
    final object = BacnetObject(
      type: BacnetObjectType.schedule,
      instance: created,
    );
    try {
      if (priorityForWriting != 16) {
        await setPriorityForWriting(created, priorityForWriting);
      }
      if (references.isNotEmpty) {
        await write(
          object,
          BacnetProperties.listOfObjectPropertyReferences,
          references,
        );
      }
      if (scheduleDefault != null) {
        await write(object, BacnetProperties.scheduleDefault, scheduleDefault);
      }
      if (effectivePeriod != null) {
        await write(object, BacnetProperties.effectivePeriod, effectivePeriod);
      }
      if (weeklySchedule != null) {
        await write(object, BacnetProperties.weeklySchedule, weeklySchedule);
      }
      if (exceptionSchedule.isNotEmpty) {
        await write(
          object,
          BacnetProperties.exceptionSchedule,
          exceptionSchedule,
        );
      }
    } on Object {
      await removeObject(BacnetObjectType.schedule, created);
      rethrow;
    }
    return created;
  }

  /// Sets the priority (1..16) a Schedule of [addSchedule] writes its
  /// members with.
  Future<void> setPriorityForWriting(int instance, int priority) {
    RangeError.checkValueInInterval(priority, 1, 16, 'priority');
    return _system.call<void>(
      (id) => SetNumberCommand(
        id,
        objectType: BacnetObjectType.schedule,
        instance: instance,
        propertyId: BacnetPropertyId.priorityForWriting,
        value: priority.toDouble(),
      ),
    );
  }

  /// Adds a Calendar object and returns its instance: its present value is
  /// true on the [dates] (dates, date ranges and week-n-days). Schedules
  /// refer to calendars in their exception schedule.
  ///
  /// ```dart
  /// await server.addCalendar(1, name: 'Holidays', dates: [
  ///   BacnetCalendarDate(BacnetDate(year: 2026, month: 12, day: 25)),
  /// ]);
  /// ```
  Future<int> addCalendar(
    int instance, {
    String? name,
    String? description,
    List<BacnetCalendarEntry> dates = const [],
  }) async {
    final created = await addObject(
      BacnetObjectType.calendar,
      instance,
      name: name,
      description: description,
    );
    if (dates.isNotEmpty) {
      try {
        await write(
          BacnetObject(type: BacnetObjectType.calendar, instance: created),
          BacnetProperties.dateList,
          dates,
        );
      } on Object {
        await removeObject(BacnetObjectType.calendar, created);
        rethrow;
      }
    }
    return created;
  }

  // ---- device instance ------------------------------------------------------

  /// Changes the instance of the Device object (e.g. as a supervisor
  /// assigned with You-Are) and announces it with an I-Am.
  Future<void> setDeviceInstance(int deviceId) async {
    RangeError.checkValueInInterval(deviceId, 0, 0x3FFFFE, 'deviceId');
    await _system.call<void>((id) => SetDeviceInstanceCommand(id, deviceId));
    _deviceId = deviceId;
  }

  /// Sends a Who-Am-I with the Vendor_Identifier, Model_Name and
  /// Serial_Number of the Device object (see [init]) to [supervisor], or
  /// broadcasts it: a supervisor answers with You-Are ([youAreRequests]).
  Future<void> sendWhoAmI({BacnetAddressRecipient? supervisor}) async {
    final identity = await _identity();
    await _system.call<void>(
      (id) => UnconfirmedRequestCommand(
        id,
        service: BacnetUnconfirmedService.whoAmI,
        payload: encodeWhoAmI(
          vendorId: identity.vendorId,
          modelName: identity.modelName,
          serialNumber: identity.serialNumber,
        ),
        network: supervisor?.network ?? 0xFFFF,
        mac: supervisor == null
            ? null
            : supervisor.network == 0
            ? supervisor.mac
            : const [],
        adr: supervisor == null || supervisor.network == 0
            ? const []
            : supervisor.mac,
      ),
    );
  }

  /// Asks a supervisor for the device instance of this server: sends
  /// Who-Am-I (to [supervisor], or broadcast) every [retryInterval] and
  /// applies the first You-Are that assigns an instance to this device
  /// (same vendor, model name and serial number). Returns the instance, or
  /// null when no supervisor answers within [timeout].
  ///
  /// ```dart
  /// await server.init(4194302, 'Room controller',
  ///     vendorId: 260, modelName: 'RC-1', serialNumber: serial);
  /// final instance = await server.requestDeviceInstance();
  /// ```
  Future<int?> requestDeviceInstance({
    BacnetAddressRecipient? supervisor,
    Duration timeout = const Duration(seconds: 30),
    Duration retryInterval = const Duration(seconds: 5),
  }) async {
    final identity = await _identity();
    final assigned = Completer<int?>();
    final subscription = youAreRequests.listen((request) {
      if (!assigned.isCompleted &&
          request.deviceId != null &&
          request.addresses(
            vendorId: identity.vendorId,
            modelName: identity.modelName,
            serialNumber: identity.serialNumber,
          )) {
        assigned.complete(request.deviceId);
      }
    });
    final retry = Timer.periodic(retryInterval, (_) {
      unawaited(sendWhoAmI(supervisor: supervisor).catchError((Object _) {}));
    });
    try {
      await sendWhoAmI(supervisor: supervisor);
      final deviceId = await assigned.future.timeout(
        timeout,
        onTimeout: () => null,
      );
      if (deviceId != null) await setDeviceInstance(deviceId);
      return deviceId;
    } finally {
      retry.cancel();
      await subscription.cancel();
    }
  }

  Future<({int vendorId, String modelName, String serialNumber})>
  _identity() async {
    final deviceId = _deviceId;
    if (deviceId == null) throw const BacnetNotInitializedException();
    Future<BacnetValue> device(BacnetPropertyId property) =>
        readProperty(BacnetObjectType.device, deviceId, property);
    return (
      vendorId: (await device(BacnetPropertyId.vendorIdentifier)).asInt ?? 0,
      modelName: (await device(BacnetPropertyId.modelName)).asString ?? '',
      serialNumber:
          (await device(BacnetPropertyId.serialNumber)).asString ?? '',
    );
  }

  // ---- channels -------------------------------------------------------------

  /// Adds a Channel object and returns its instance: a WriteGroup of a
  /// group in [controlGroups] (at most 16) with a value for
  /// [channelNumber], or a write of its Present_Value, writes the value to
  /// the [members] (properties of objects of this server, at most 32).
  /// Those writes arrive as [writeEvents] with `internal` set, the requests
  /// as [writeGroupEvents].
  ///
  /// ```dart
  /// await server.addChannel(1,
  ///     name: 'Lights floor 2',
  ///     channelNumber: 7,
  ///     controlGroups: [5],
  ///     members: const [
  ///       BacnetDeviceObjectPropertyReference(
  ///         object: BacnetObject(type: BacnetObjectType.analogOutput,
  ///             instance: 1),
  ///         property: BacnetPropertyId.presentValue,
  ///       ),
  ///     ]);
  /// ```
  Future<int> addChannel(
    int instance, {
    required int channelNumber,
    String? name,
    String? description,
    List<int> controlGroups = const [],
    List<BacnetDeviceObjectPropertyReference> members = const [],
  }) async {
    RangeError.checkValueInInterval(channelNumber, 0, 0xFFFF, 'channelNumber');
    if (controlGroups.length > 16) {
      throw ArgumentError.value(controlGroups, 'controlGroups', 'at most 16');
    }
    for (final group in controlGroups) {
      RangeError.checkValueInInterval(group, 1, 0xFFFFFFFF, 'controlGroups');
    }
    if (members.length > 32) {
      throw ArgumentError.value(members, 'members', 'at most 32');
    }
    final deviceId = _deviceId;
    if (deviceId == null) throw const BacnetNotInitializedException();
    final device = BacnetObject(
      type: BacnetObjectType.device,
      instance: deviceId,
    );
    for (final member in members) {
      if (member.device != null && member.device != device) {
        throw ArgumentError.value(
          member,
          'members',
          'channels write objects of this server only',
        );
      }
    }
    final created = await addObject(
      BacnetObjectType.channel,
      instance,
      name: name,
      description: description,
    );
    try {
      await setProperty(
        BacnetObjectType.channel,
        created,
        BacnetPropertyId.channelNumber,
        BacnetUnsigned(channelNumber),
      );
      // fixed size arrays: written element by element
      for (final (index, group) in controlGroups.indexed) {
        await setProperty(
          BacnetObjectType.channel,
          created,
          BacnetPropertyId.controlGroups,
          BacnetUnsigned(group),
          arrayIndex: index + 1,
        );
      }
      for (final (index, member) in members.indexed) {
        await setProperty(
          BacnetObjectType.channel,
          created,
          BacnetPropertyId.listOfObjectPropertyReferences,
          // the stack writes the members that name the device
          BacnetDeviceObjectPropertyReference.listToValue([
            BacnetDeviceObjectPropertyReference(
              object: member.object,
              property: member.property,
              arrayIndex: member.arrayIndex,
              device: device,
            ),
          ]),
          arrayIndex: index + 1,
        );
      }
    } on Object {
      await removeObject(BacnetObjectType.channel, created);
      rethrow;
    }
    return created;
  }

  // ---- lighting and color objects -------------------------------------------

  /// Adds a Lighting Output object (dimmable light): clients drive it by
  /// writing [BacnetProperties.lightingCommand] (a [BacnetLightingCommand])
  /// or its Present_Value (0.0..100.0 %). Returns its instance.
  ///
  /// ```dart
  /// await server.addLightingOutput(1, name: 'Desk lamp');
  /// // a client ramps it to 80 % over two seconds:
  /// await client.write(device, lamp, BacnetProperties.lightingCommand,
  ///     const BacnetLightingCommand(
  ///       operation: BacnetLightingOperation.fadeTo,
  ///       targetLevel: 80,
  ///       fadeTime: Duration(seconds: 2),
  ///     ));
  /// ```
  Future<int> addLightingOutput(
    int instance, {
    String? name,
    String? description,
  }) => addObject(
    BacnetObjectType.lightingOutput,
    instance,
    name: name,
    description: description,
  );

  /// Adds a Binary Lighting Output object (a switched light): clients write
  /// its Present_Value ([BacnetBinaryLightingPV]). Returns its instance.
  Future<int> addBinaryLightingOutput(
    int instance, {
    String? name,
    String? description,
  }) => addObject(
    BacnetObjectType.binaryLightingOutput,
    instance,
    name: name,
    description: description,
  );

  /// Adds a Color object (CIE xy chromaticity): clients drive it by writing
  /// [BacnetProperties.colorCommand] (a [BacnetColorCommand]). Returns its
  /// instance.
  Future<int> addColor(int instance, {String? name, String? description}) =>
      addObject(
        BacnetObjectType.color,
        instance,
        name: name,
        description: description,
      );

  /// Adds a Color Temperature object (correlated color temperature in
  /// kelvin): clients drive it by writing [BacnetProperties.colorCommand].
  /// Returns its instance.
  Future<int> addColorTemperature(
    int instance, {
    String? name,
    String? description,
  }) => addObject(
    BacnetObjectType.colorTemperature,
    instance,
    name: name,
    description: description,
  );

  // ---- control and grouping objects -----------------------------------------

  /// Adds a Loop object (a PID control loop). Returns its instance. Configure
  /// its setpoint, process variable and manipulated variable references and
  /// tuning constants with [setProperty].
  Future<int> addLoop(int instance, {String? name, String? description}) =>
      addObject(
        BacnetObjectType.loop,
        instance,
        name: name,
        description: description,
      );

  /// Adds a Timer object (ASHRAE 135 clause 12.X). Returns its instance.
  Future<int> addTimer(int instance, {String? name, String? description}) =>
      addObject(
        BacnetObjectType.timer,
        instance,
        name: name,
        description: description,
      );

  /// Adds an Accumulator object (a pulse counter, e.g. a utility meter).
  /// Returns its instance.
  Future<int> addAccumulator(
    int instance, {
    String? name,
    String? description,
  }) => addObject(
    BacnetObjectType.accumulator,
    instance,
    name: name,
    description: description,
  );

  /// Adds an Averaging object (tracks the minimum, maximum and average of a
  /// monitored property over a window). Returns its instance.
  Future<int> addAveraging(int instance, {String? name, String? description}) =>
      addObject(
        BacnetObjectType.averaging,
        instance,
        name: name,
        description: description,
      );

  /// Adds a Load Control object (sheds electrical load on request, ASHRAE
  /// 135 clause 12.X). Returns its instance.
  Future<int> addLoadControl(
    int instance, {
    String? name,
    String? description,
  }) => addObject(
    BacnetObjectType.loadControl,
    instance,
    name: name,
    description: description,
  );

  /// Adds a Structured View object (groups other objects into a hierarchy for
  /// navigation). Returns its instance; add its members by writing
  /// Subordinate_List with [setProperty].
  Future<int> addStructuredView(
    int instance, {
    String? name,
    String? description,
  }) => addObject(
    BacnetObjectType.structuredView,
    instance,
    name: name,
    description: description,
  );

  // ---- backup and restore ---------------------------------------------------

  /// Lets clients back up and restore this server (ASHRAE 135 clause 19.1,
  /// see `BacnetDeviceBackups`): [files] are the instances of the File
  /// objects of [addFile] that hold the configuration of the application
  /// (Configuration_Files, at most 16).
  ///
  /// When a client starts a backup, [prepareBackup] writes the current
  /// configuration into the files before the client reads them; after a
  /// restore [applyRestore] reads the restored files and applies them.
  /// An error thrown by either reports a failure to the client
  /// (Backup_And_Restore_State). A procedure fails when the client sends no
  /// request for [failureTimeout]. The requests also arrive as
  /// [reinitializeRequests].
  ///
  /// ```dart
  /// await server.addFile(1, name: 'settings.json');
  /// await server.enableBackup(
  ///   files: [1],
  ///   prepareBackup: () =>
  ///       server.setFileContent(1, utf8.encode(jsonEncode(settings))),
  ///   applyRestore: () async {
  ///     settings = jsonDecode(utf8.decode(await server.fileContent(1)));
  ///   },
  /// );
  /// ```
  Future<void> enableBackup({
    required List<int> files,
    Future<void> Function()? prepareBackup,
    Future<void> Function()? applyRestore,
    Duration failureTimeout = const Duration(minutes: 5),
  }) async {
    if (files.length > 16) {
      throw ArgumentError.value(files, 'files', 'at most 16 files');
    }
    final seconds = failureTimeout.inSeconds;
    RangeError.checkValueInInterval(seconds, 0, 0xFFFF, 'failureTimeout');
    await _backupRequests?.cancel();
    _backupRequests = reinitializeRequests.listen((request) async {
      switch (request.state) {
        case BacnetReinitializedState.startBackup when prepareBackup != null:
          await _backupStep(
            prepareBackup,
            BacnetBackupState.performingABackup,
            BacnetBackupState.backupFailure,
          );
        case BacnetReinitializedState.endRestore when applyRestore != null:
          await _backupStep(
            applyRestore,
            BacnetBackupState.idle,
            BacnetBackupState.restoreFailure,
          );
      }
    });
    await _system.call<void>(
      (id) => BackupConfigureCommand(
        id,
        files: files,
        prepare: prepareBackup != null,
        apply: applyRestore != null,
        failureTimeoutSeconds: seconds,
      ),
    );
  }

  Future<void> _backupStep(
    Future<void> Function() step,
    BacnetBackupState success,
    BacnetBackupState failure,
  ) async {
    var state = success;
    try {
      await step();
    } on Object catch (e, stackTrace) {
      _system.log(
        BacnetLogLevel.error,
        'backup or restore of the application failed',
        e,
        stackTrace,
      );
      state = failure;
    }
    try {
      await _system.call<void>((id) => BackupStateCommand(id, state));
    } on BacnetException {
      // the stack stopped
    }
  }

  /// Backup_And_Restore_State of this server (after [init]).
  Future<BacnetBackupState> backupState() async {
    final deviceId = _deviceId;
    if (deviceId == null) throw const BacnetNotInitializedException();
    final value = await readProperty(
      BacnetObjectType.device,
      deviceId,
      BacnetPropertyId.backupAndRestoreState,
    );
    return BacnetBackupState(value.asInt ?? 0);
  }

  // ---- trend logs -----------------------------------------------------------

  /// Adds a Trend Log object and returns its instance. Clients read its
  /// records with ReadRange ([BacnetClient.getTrendLog]).
  ///
  /// With [source] (a property of an object of this server) the log reads
  /// the property every [logInterval] and records its value and the
  /// Status_Flags of the object; without it the application records values
  /// with [logValue]. The log keeps the last [bufferSize] records (or stops
  /// when full with [stopWhenFull]) and records while [enable] is true,
  /// between [startTime] and [stopTime] when given.
  ///
  /// ```dart
  /// await server.addTrendLog(
  ///   1,
  ///   name: 'Supply temperature log',
  ///   source: const BacnetDeviceObjectPropertyReference(
  ///     object: BacnetObject(type: BacnetObjectType.analogInput, instance: 1),
  ///     property: BacnetPropertyId.presentValue,
  ///   ),
  ///   logInterval: const Duration(minutes: 5),
  ///   bufferSize: 10000,
  /// );
  /// ```
  Future<int> addTrendLog(
    int instance, {
    String? name,
    String? description,
    BacnetDeviceObjectPropertyReference? source,
    Duration logInterval = const Duration(minutes: 1),
    int bufferSize = 1000,
    bool stopWhenFull = false,
    BacnetDateTime? startTime,
    BacnetDateTime? stopTime,
    bool enable = true,
  }) async {
    final hundredths = logInterval.inMilliseconds ~/ 10;
    if (hundredths < 1) {
      throw ArgumentError.value(logInterval, 'logInterval', 'below 10 ms');
    }
    RangeError.checkValueInInterval(bufferSize, 1, 100000, 'bufferSize');
    final created = await addObject(
      BacnetObjectType.trendLog,
      instance,
      name: name,
      description: description,
    );
    final object = BacnetObject(
      type: BacnetObjectType.trendLog,
      instance: created,
    );
    try {
      await write(object, BacnetProperties.bufferSize, bufferSize);
      await write(object, BacnetProperties.logInterval, hundredths);
      await write(object, BacnetProperties.stopWhenFull, stopWhenFull);
      if (startTime != null) {
        await write(object, BacnetProperties.startTime, startTime);
      }
      if (stopTime != null) {
        await write(object, BacnetProperties.stopTime, stopTime);
      }
      if (source != null) {
        await write(object, BacnetProperties.logDeviceObjectProperty, source);
      }
      await write(object, BacnetProperties.enable, enable);
    } on Object {
      await removeObject(BacnetObjectType.trendLog, created);
      rethrow;
    }
    return created;
  }

  /// Records [value] with the current time in Trend Log [instance] of
  /// [addTrendLog]: a [BacnetNull], [BacnetBoolean], [BacnetReal],
  /// [BacnetDouble] (recorded as Real), [BacnetEnumerated],
  /// [BacnetUnsigned], [BacnetSigned] or a [BacnetBitString] of up to 32
  /// bits. Returns false while the log is disabled.
  Future<bool> logValue(
    int instance,
    BacnetValue value, {
    BacnetStatusFlags? statusFlags,
  }) {
    final writer = BacnetWriter();
    encodeApplicationValue(writer, value);
    final payload = writer.toBytes();
    return _system.call<bool>(
      (id) => TrendLogAppendCommand(
        id,
        instance,
        payload,
        statusFlags: switch (statusFlags) {
          null => -1,
          final flags =>
            (flags.inAlarm ? 1 : 0) |
                (flags.fault ? 2 : 0) |
                (flags.overridden ? 4 : 0) |
                (flags.outOfService ? 8 : 0),
        },
      ),
    );
  }

  // ---- alarms and events ----------------------------------------------------

  /// Adds Notification Class [instance] (0..63): the recipients,
  /// priorities and acknowledgement rules of the alarms and events of the
  /// objects that refer to it.
  ///
  /// Clients add themselves to the recipients with AddListElement
  /// ([BacnetClient.addListElements]); [recipients] are the initial ones.
  ///
  /// ```dart
  /// await server.addNotificationClass(1, name: 'Critical alarms');
  /// await server.enableEventReporting(
  ///   const BacnetObject(type: BacnetObjectType.analogInput, instance: 1),
  ///   notificationClass: 1,
  ///   highLimit: 30,
  ///   lowLimit: 10,
  ///   deadband: 0.5,
  /// );
  /// ```
  Future<void> addNotificationClass(
    int instance, {
    String? name,
    String? description,
    BacnetEventPriorities priorities = const BacnetEventPriorities(
      toOffNormal: 100,
      toFault: 100,
      toNormal: 200,
    ),
    BacnetEventTransitionBits ackRequired = const BacnetEventTransitionBits(
      toOffNormal: true,
      toFault: true,
    ),
    List<BacnetDestination> recipients = const [],
  }) async {
    await addObject(
      BacnetObjectType.notificationClass,
      instance,
      name: name,
      description: description,
    );
    final object = BacnetObject(
      type: BacnetObjectType.notificationClass,
      instance: instance,
    );
    await write(object, BacnetProperties.priority, priorities);
    await write(object, BacnetProperties.ackRequired, ackRequired);
    if (recipients.isNotEmpty) {
      await write(object, BacnetProperties.recipientList, recipients);
    }
  }

  /// Enables the event algorithm (intrinsic reporting) of an Analog or
  /// Binary Input or Value: the server evaluates it every second and sends
  /// event notifications to the recipients of [notificationClass].
  ///
  /// Analog objects report OUT_OF_RANGE when the present value exceeds
  /// [highLimit] or falls below [lowLimit] for [timeDelay] (and return to
  /// normal [deadband] inside the limits); binary objects report
  /// CHANGE_OF_STATE when the present value equals [alarmValue]. A
  /// Reliability other than no-fault-detected reports a fault.
  /// [eventEnable] selects the reported transitions.
  Future<void> enableEventReporting(
    BacnetObject object, {
    required int notificationClass,
    double? highLimit,
    double? lowLimit,
    double deadband = 0,
    BacnetBinaryPV? alarmValue,
    BacnetEventTransitionBits eventEnable = const BacnetEventTransitionBits(
      toOffNormal: true,
      toFault: true,
      toNormal: true,
    ),
    BacnetNotifyType notifyType = BacnetNotifyType.alarm,
    Duration timeDelay = Duration.zero,
  }) async {
    await write(object, BacnetProperties.notificationClass, notificationClass);
    await write(object, BacnetProperties.notifyType, notifyType);
    await write(object, BacnetProperties.timeDelay, timeDelay.inSeconds);
    if (highLimit != null) {
      await write(object, BacnetProperties.highLimit, highLimit);
    }
    if (lowLimit != null) {
      await write(object, BacnetProperties.lowLimit, lowLimit);
    }
    if (highLimit != null || lowLimit != null) {
      await write(object, BacnetProperties.deadband, deadband);
      await write(
        object,
        BacnetProperties.limitEnable,
        BacnetLimitEnable(
          lowLimit: lowLimit != null,
          highLimit: highLimit != null,
        ),
      );
    }
    if (alarmValue != null) {
      await write(object, BacnetProperties.binaryAlarmValue, alarmValue);
    }
    // last: the algorithm starts with the complete configuration
    await write(object, BacnetProperties.eventEnable, eventEnable);
  }

  /// Adds an Event Enrollment object (ASHRAE 135 clause 12.12) that monitors a
  /// property of another object — local or, once bound, remote — and reports
  /// events to the recipients of [notificationClass]. Returns its instance.
  ///
  /// It evaluates the OUT_OF_RANGE algorithm every second on the REAL value of
  /// [property] (Present_Value by default; pass [arrayIndex] for an array
  /// element) of [monitored]: a value above [highLimit] or below [lowLimit]
  /// for [timeDelay] reports a to-offnormal event, and a return inside the
  /// limits by more than [deadband] reports to-normal. Leave a limit null to
  /// disable that side. [eventEnable] selects the reported transitions and
  /// [notifyType] whether they are alarms or events.
  ///
  /// ```dart
  /// await server.addNotificationClass(1, recipients: [...]);
  /// await server.addAnalogValue(7, presentValue: 20);
  /// await server.addEventEnrollment(
  ///   1,
  ///   monitored: const BacnetObject(
  ///     type: BacnetObjectType.analogValue,
  ///     instance: 7,
  ///   ),
  ///   notificationClass: 1,
  ///   highLimit: 30,
  ///   lowLimit: 10,
  ///   deadband: 0.5,
  /// );
  /// ```
  Future<int> addEventEnrollment(
    int instance, {
    required BacnetObject monitored,
    required int notificationClass,
    BacnetPropertyId property = BacnetPropertyId.presentValue,
    int? arrayIndex,
    double? highLimit,
    double? lowLimit,
    double deadband = 0,
    Duration timeDelay = Duration.zero,
    BacnetEventTransitionBits eventEnable = const BacnetEventTransitionBits(
      toOffNormal: true,
      toFault: true,
      toNormal: true,
    ),
    BacnetNotifyType notifyType = BacnetNotifyType.alarm,
    String? name,
    String? description,
  }) async {
    if (timeDelay.isNegative) {
      throw ArgumentError.value(timeDelay, 'timeDelay', 'must not be negative');
    }
    if (arrayIndex != null) {
      RangeError.checkValueInInterval(arrayIndex, 0, 0xFFFFFFFE, 'arrayIndex');
    }
    final created = await addObject(
      BacnetObjectType.eventEnrollment,
      instance,
      name: name,
      description: description,
    );
    await _system.call<void>(
      (id) => EventEnrollmentCommand(
        id,
        created,
        monitoredType: monitored.type,
        monitoredInstance: monitored.instance,
        monitoredProperty: property,
        monitoredIndex: arrayIndex ?? _arrayAll,
        lowLimit: lowLimit ?? double.negativeInfinity,
        highLimit: highLimit ?? double.infinity,
        deadband: deadband,
        timeDelaySeconds: timeDelay.inSeconds,
        notificationClass: notificationClass,
        eventEnable:
            (eventEnable.toOffNormal ? 1 : 0) |
            (eventEnable.toFault ? 2 : 0) |
            (eventEnable.toNormal ? 4 : 0),
        notifyType: notifyType,
      ),
    );
    return created;
  }

  /// Adds an Audit Log object (ASHRAE 135-2016bi) that stores audit records —
  /// from an [addAuditReporter] on this device, or received
  /// AuditNotifications. Returns its instance. Read its records with
  /// [BacnetClient.queryAuditLog] or ReadRange of Log_Buffer. [enabled]
  /// controls whether it accepts records (a disabled log drops them).
  Future<int> addAuditLog(
    int instance, {
    String? name,
    String? description,
    bool enabled = true,
  }) async {
    final created = await addObject(
      BacnetObjectType.auditLog,
      instance,
      name: name,
      description: description,
    );
    await _system.call<void>(
      (id) => AuditLogConfigureCommand(id, created, enabled: enabled),
    );
    return created;
  }

  /// Adds an Audit Reporter object (ASHRAE 135-2016bi) that generates an audit
  /// record for each operation in [operations] (by default writes) performed
  /// on this device by a remote client. Returns its instance.
  ///
  /// Records are stored in Audit Log [auditLog] (null for none) and sent as an
  /// AuditNotification to [recipient] (null for none). [auditLevel] other than
  /// [BacnetAuditLevel.none] enables reporting.
  ///
  /// ```dart
  /// final log = await server.addAuditLog(1, name: 'Audit');
  /// await server.addAuditReporter(
  ///   1,
  ///   auditLog: log,
  ///   recipient: BacnetRecipient.ip('192.168.1.10', 47808),
  /// );
  /// ```
  Future<int> addAuditReporter(
    int instance, {
    String? name,
    String? description,
    BacnetAuditLevel auditLevel = BacnetAuditLevel.auditAll,
    List<BacnetAuditOperation> operations = const [BacnetAuditOperation.write],
    int? auditLog,
    BacnetRecipient? recipient,
    Duration maxSendDelay = Duration.zero,
  }) async {
    var mask = 0;
    for (final operation in operations) {
      if (operation >= 0 && operation < 32) {
        mask |= 1 << operation;
      }
    }
    final created = await addObject(
      BacnetObjectType.auditReporter,
      instance,
      name: name,
      description: description,
    );
    await _system.call<void>(
      (id) => AuditReporterConfigureCommand(
        id,
        created,
        auditLevel: auditLevel,
        operations: mask,
        auditLogInstance: auditLog ?? _arrayAll,
        maxSendDelaySeconds: maxSendDelay.inSeconds,
        recipient: recipient == null ? null : _timeRecipient(recipient),
      ),
    );
    return created;
  }

  /// Makes the server advertise itself as the BACnet router to [networks]
  /// (ASHRAE 135 clause 6, BIBB NM-RC-B): it answers Who-Is-Router-To-Network
  /// and Initialize-Routing-Table for them (so `client.discoverRouters` finds
  /// it). Forwarding APDUs to devices behind the router is not implemented.
  /// At most 16 networks, each 1..65535.
  ///
  /// ```dart
  /// await server.enableRouting([100, 200]);
  /// ```
  Future<void> enableRouting(List<int> networks) {
    if (networks.length > 16) {
      throw ArgumentError.value(networks, 'networks', 'at most 16');
    }
    for (final network in networks) {
      RangeError.checkValueInInterval(network, 1, 0xFFFF, 'network');
    }
    return _system.call<void>(
      (id) => RouterConfigureCommand(id, List<int>.of(networks)),
    );
  }

  /// Stops advertising the server as a router (see [enableRouting]).
  Future<void> disableRouting() =>
      _system.call<void>((id) => RouterConfigureCommand(id, const []));

  /// Broadcasts an I-Am for the local device.
  Future<void> sendIAm() => _system.call<void>(SendIAmCommand.new);

  /// Enables the Time Master (ASHRAE 135 clause 13.12): the server sends a
  /// TimeSynchronization — or a UTCTimeSynchronization when [utc] — every
  /// [interval] to [recipients], using the host clock (and, for [utc], the
  /// UTC offset of the Device object).
  ///
  /// Each recipient is a device ([BacnetRecipient.device], resolved through
  /// the binding table — nothing is sent to it until it is bound), an address
  /// ([BacnetRecipient.ip]), or a local broadcast (a [BacnetAddressRecipient]
  /// with an empty mac). When [recipients] is empty the server broadcasts on
  /// the local network. At most 16 recipients.
  ///
  /// When [alignToClock] the sends are aligned to the wall clock, [offset]
  /// past each interval (e.g. an hourly sync with a one-minute offset fires at
  /// 00:01, 01:01, ...).
  ///
  /// ```dart
  /// // broadcast UTC time every hour, aligned to the top of the hour
  /// await server.enableTimeMaster(
  ///   interval: const Duration(hours: 1),
  ///   utc: true,
  ///   alignToClock: true,
  /// );
  /// ```
  Future<void> enableTimeMaster({
    required Duration interval,
    List<BacnetRecipient> recipients = const [],
    bool utc = false,
    bool alignToClock = false,
    Duration offset = Duration.zero,
  }) {
    final seconds = interval.inSeconds;
    if (seconds <= 0) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
    if (offset.isNegative) {
      throw ArgumentError.value(offset, 'offset', 'must not be negative');
    }
    if (recipients.length > 16) {
      throw ArgumentError.value(recipients, 'recipients', 'at most 16');
    }
    return _system.call<void>(
      (id) => TimeMasterCommand(
        id,
        enabled: true,
        intervalSeconds: seconds,
        utc: utc,
        align: alignToClock,
        offsetSeconds: offset.inSeconds,
        recipients: [for (final r in recipients) _timeRecipient(r)],
      ),
    );
  }

  /// Disables the Time Master started by [enableTimeMaster].
  Future<void> disableTimeMaster() => _system.call<void>(
    (id) => TimeMasterCommand(
      id,
      enabled: false,
      intervalSeconds: 60,
      utc: false,
      align: false,
      offsetSeconds: 0,
      recipients: const [],
    ),
  );

  static TimeMasterRecipient _timeRecipient(BacnetRecipient recipient) =>
      switch (recipient) {
        BacnetDeviceRecipient(:final deviceId) => TimeMasterRecipient(
          deviceId: deviceId,
        ),
        BacnetAddressRecipient(:final network, :final mac) =>
          TimeMasterRecipient(network: network, mac: mac),
      };

  /// The number the native engine stores; NaN relinquishes.
  static double _number(BacnetValue value) => switch (value) {
    BacnetNull() => double.nan,
    BacnetBoolean(:final value) => value ? 1 : 0,
    BacnetReal(:final value) || BacnetDouble(:final value) => value,
    BacnetUnsigned(:final value) ||
    BacnetSigned(:final value) ||
    BacnetEnumerated(:final value) => value.toDouble(),
    _ => throw ArgumentError.value(
      value,
      'value',
      'not supported as present value, use setProperty',
    ),
  };

  /// Releases the stack (stopped when no client or server uses it).
  Future<void> close() async {
    await _backupRequests?.cancel();
    _backupRequests = null;
    if (!_started) return;
    _started = false;
    await _system.release();
  }

  /// Disposes of the server and releases resources.
  ///
  /// Prefer [close] to await the shutdown.
  void dispose() {
    unawaited(close());
  }
}
