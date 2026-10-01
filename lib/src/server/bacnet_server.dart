/// @docImport '../client/bacnet_client.dart';
/// @docImport '../constants/enumerations.dart';
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../codec/value_encoding.dart';
import '../codec/writer.dart';
import '../constants/engineering_units.dart';
import '../constants/enumerations.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/bacnet_config.dart';
import '../core/logger.dart';
import '../models/alarms.dart';
import '../models/bacnet_property.dart';
import '../models/bacnet_value.dart';
import '../models/complex_values.dart';
import '../models/events.dart';
import '../native/bacnet_system.dart';
import '../native/protocol.dart';

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
  bool _started = false;

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
    String? password,
  }) {
    _checkPassword(password);
    return _system.call<void>(
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
        },
      ),
    );
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
  }) {
    return _system.call<int>(
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
  }

  /// Adds a File object whose content the server keeps in memory and
  /// returns its instance: remote clients read it with AtomicReadFile
  /// (stream access) and, unless [readOnly], write it with AtomicWriteFile
  /// ([fileWrites]) and change its size by writing File_Size.
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
  }) async {
    final created = await addObject(
      BacnetObjectType.file,
      instance,
      name: name,
      description: description,
    );
    await configureFile(created, fileType: fileType, readOnly: readOnly);
    if (content.isNotEmpty) await setFileContent(created, content);
    return created;
  }

  /// Sets the File_Type (a media type) and Read_Only of a File object of
  /// [addFile]; null keeps the value.
  Future<void> configureFile(
    int instance, {
    String? fileType,
    bool? readOnly,
  }) => _system.call<void>(
    (id) => ConfigureFileCommand(
      id,
      instance,
      fileType: fileType,
      readOnly: readOnly,
    ),
  );

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
  Future<void> removeObject(BacnetObjectType objectType, int instance) =>
      _system.call<void>((id) => DeleteObjectCommand(id, objectType, instance));

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

  /// Broadcasts an I-Am for the local device.
  Future<void> sendIAm() => _system.call<void>(SendIAmCommand.new);

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
