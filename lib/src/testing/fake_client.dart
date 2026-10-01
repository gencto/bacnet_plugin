import 'dart:async';
import 'dart:typed_data';

import '../client/bacnet_client.dart';
import '../client/read_specs.dart';
import '../codec/requests.dart';
import '../codec/responses.dart';
import '../constants/engineering_units.dart';
import '../constants/enumerations.dart';
import '../constants/errors.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../constants/services.dart';
import '../core/bacnet_config.dart';
import '../core/cancel_token.dart';
import '../core/exceptions.dart';
import '../core/types.dart';
import '../models/alarms.dart';
import '../models/bacnet_property.dart';
import '../models/bacnet_stats.dart';
import '../models/bacnet_value.dart';
import '../models/channels.dart';
import '../models/complex_values.dart';
import '../models/events.dart';
import '../models/files.dart';
import '../models/network.dart';
import '../models/rpm_models.dart';
import '../models/trend_log_data.dart';
import '../models/wpm_models.dart';

/// A request received by a [FakeBacnetClient], for assertions in tests.
final class FakeBacnetRequest {
  /// Creates a request record.
  const FakeBacnetRequest(
    this.service, {
    this.deviceId,
    this.object,
    this.propertyId,
    this.value,
    this.priority,
    this.time,
    this.address,
    this.objectName,
    this.source,
    this.networkMessage,
    this.arguments = const {},
  });

  /// Client method, e.g. `readProperty`, `writeProperty`, `subscribeCOV`,
  /// `acknowledgeAlarm`.
  final String service;

  /// Target device.
  final int? deviceId;

  /// Target object.
  final BacnetObject? object;

  /// Target property.
  final BacnetPropertyId? propertyId;

  /// Written value.
  final BacnetValue? value;

  /// Write priority.
  final int? priority;

  /// Time sent with `timeSynchronization`.
  final DateTime? time;

  /// BBMD address (`host:port`) of `registerForeignDevice`, destination
  /// of `sendNetworkMessage` (null for a broadcast).
  final String? address;

  /// Object name searched by `sendWhoHas`.
  final String? objectName;

  /// Acknowledgement source of `acknowledgeAlarm`.
  final String? source;

  /// Message of `sendNetworkMessage`.
  final BacnetNetworkMessage? networkMessage;

  /// Other arguments by name, e.g. `serialNumber` of `sendYouAre` or
  /// `changes` of `writeGroup`.
  final Map<String, Object?> arguments;

  @override
  String toString() =>
      'FakeBacnetRequest($service, device: $deviceId, object: $object, '
      'property: $propertyId, value: $value)';
}

/// An object of a [FakeBacnetDevice].
final class FakeBacnetObject {
  FakeBacnetObject._(this.device, this.type, this.instance, this.commandable);

  /// The device hosting the object.
  final FakeBacnetDevice device;

  /// Object type.
  final BacnetObjectType type;

  /// Object instance.
  final int instance;

  /// Whether the present value is commanded through a priority array.
  final bool commandable;

  /// Property values.
  final Map<BacnetPropertyId, BacnetValue> properties = {};

  final List<BacnetValue> _priorityArray = List.filled(16, const BacnetNull());

  /// Trend Log records returned by [FakeBacnetClient.getTrendLog].
  final List<TrendLogEntry> records = [];

  /// The object identifier.
  BacnetObject get identifier => BacnetObject(type: type, instance: instance);

  /// Value of [property], or null.
  BacnetValue? operator [](BacnetPropertyId property) => properties[property];

  /// Sets [property] like a change in the field (not a client write) and
  /// notifies COV subscribers.
  void operator []=(BacnetPropertyId property, BacnetValue value) {
    properties[property] = value;
    device._changed(this, property);
  }

  List<int>? _file;

  /// Content of a File object ([FakeBacnetDevice.addFile]).
  Uint8List get fileContent => Uint8List.fromList(_file ?? const []);

  set fileContent(List<int> content) {
    _file = [...content];
    properties[BacnetPropertyId.fileSize] = BacnetUnsigned(content.length);
  }

  /// Applies a client write with WriteProperty semantics.
  void _write(BacnetPropertyId property, BacnetValue value, int priority) {
    if (property == BacnetPropertyId.fileSize && _file != null) {
      final size = value.asInt ?? _file!.length;
      _file = size <= _file!.length
          ? _file!.sublist(0, size)
          : [..._file!, ...List.filled(size - _file!.length, 0)];
      properties[property] = BacnetUnsigned(size);
      device._changed(this, property);
      return;
    }
    if (property == BacnetPropertyId.presentValue && commandable) {
      _priorityArray[(priority.clamp(1, 16)) - 1] = value;
      _publishPriorityArray();
      properties[property] = _priorityArray.firstWhere(
        (v) => v is! BacnetNull,
        orElse: () =>
            properties[BacnetPropertyId.relinquishDefault] ??
            const BacnetNull(),
      );
    } else {
      properties[property] = value;
    }
    device._changed(this, property);
  }

  /// Enables event reporting: transitions reported with [reportEvent] go
  /// to the recipients of Notification Class [notificationClass] (add it
  /// with [FakeBacnetDevice.addNotificationClass]).
  void enableEventReporting({
    required int notificationClass,
    BacnetNotifyType notifyType = BacnetNotifyType.alarm,
    BacnetEventTransitionBits eventEnable = _allTransitions,
  }) {
    properties.addAll({
      BacnetPropertyId.notificationClass: BacnetUnsigned(notificationClass),
      BacnetPropertyId.notifyType: BacnetEnumerated(notifyType),
      BacnetPropertyId.eventEnable: eventEnable.toValue(),
      BacnetPropertyId.eventState: BacnetEnumerated(_eventState),
      BacnetPropertyId.ackedTransitions: _acked.toValue(),
      BacnetPropertyId.eventTimeStamps: BacnetList([
        for (final stamp in _stamps) stamp.toValue(),
      ]),
    });
  }

  BacnetEventState _eventState = BacnetEventState.normal;
  BacnetEventTransitionBits _acked = _allTransitions;
  final List<BacnetTimeStamp> _stamps = List.filled(
    3,
    const BacnetTimeStampDateTime(BacnetDateTime(BacnetDate(), BacnetTime())),
  );

  /// Current event state.
  BacnetEventState get eventState => _eventState;

  /// Reports that the object entered [toState], like an event algorithm of
  /// the device: updates Event_State, Event_Time_Stamps and
  /// Acked_Transitions, and sends an [EventNotificationEvent] to every
  /// recipient of the Notification Class that wants the transition.
  /// Returns the notification (with process identifier 0).
  ///
  /// [eventType] defaults to the type of [eventValues]. Call
  /// [enableEventReporting] first.
  EventNotificationEvent reportEvent(
    BacnetEventState toState, {
    BacnetEventValues? eventValues,
    BacnetEventType? eventType,
    String? messageText,
    DateTime? time,
  }) {
    final classNumber = properties[BacnetPropertyId.notificationClass]?.asInt;
    if (classNumber == null) {
      throw StateError('event reporting of $identifier is not enabled');
    }
    final transition = BacnetEventTransition.into(toState);
    final notificationClass = device.object(
      BacnetObjectType.notificationClass,
      classNumber,
    );
    final ackRequired = _transitionBit(
      _decodeOr(
        notificationClass?[BacnetPropertyId.ackRequired],
        BacnetEventTransitionBits.fromValue,
        const BacnetEventTransitionBits(),
      ),
      transition,
    );
    final priorities = _decodeOr(
      notificationClass?[BacnetPropertyId.priority],
      BacnetEventPriorities.fromValue,
      const BacnetEventPriorities(
        toOffNormal: 255,
        toFault: 255,
        toNormal: 255,
      ),
    );
    final enabled = _transitionBit(
      _decodeOr(
        properties[BacnetPropertyId.eventEnable],
        BacnetEventTransitionBits.fromValue,
        _allTransitions,
      ),
      transition,
    );
    final timeStamp = BacnetTimeStampDateTime(
      BacnetDateTime.fromDateTime(time ?? DateTime.now()),
    );
    final notification = EventNotificationEvent(
      processId: 0,
      deviceId: device.deviceId,
      object: identifier,
      timeStamp: timeStamp,
      notificationClass: classNumber,
      priority: priorities[transition],
      eventType:
          eventType ?? eventValues?.eventType ?? BacnetEventType.changeOfState,
      messageText: messageText,
      notifyType: BacnetNotifyType(
        properties[BacnetPropertyId.notifyType]?.asInt ??
            BacnetNotifyType.alarm,
      ),
      ackRequired: enabled && ackRequired,
      fromState: _eventState,
      toState: toState,
      eventValues: eventValues,
    );
    _eventState = toState;
    _stamps[transition.index] = timeStamp;
    _acked = _withTransition(_acked, transition, !(enabled && ackRequired));
    _publishEventState();
    if (enabled) device._notifyRecipients(notification, transition);
    return notification;
  }

  void _acknowledge(BacnetEventState state, BacnetTimeStamp timeStamp) {
    final transition = BacnetEventTransition.into(state);
    if (_transitionBit(_acked, transition)) {
      if (state != _eventState) {
        throw device._error(
          BacnetErrorClass.services,
          BacnetErrorCode.invalidEventState,
        );
      }
    } else {
      if (timeStamp != _stamps[transition.index]) {
        throw device._error(
          BacnetErrorClass.services,
          BacnetErrorCode.invalidTimeStamp,
        );
      }
      _acked = _withTransition(_acked, transition, true);
      _publishEventState();
    }
    final classNumber =
        properties[BacnetPropertyId.notificationClass]?.asInt ?? 0;
    device._notifyRecipients(
      EventNotificationEvent(
        processId: 0,
        deviceId: device.deviceId,
        object: identifier,
        timeStamp: timeStamp,
        notificationClass: classNumber,
        priority: 0,
        eventType: BacnetEventType.none,
        notifyType: BacnetNotifyType.ackNotification,
        toState: state,
      ),
      transition,
    );
  }

  BacnetEventSummary? get _eventSummary {
    final enable = _decodeOr(
      properties[BacnetPropertyId.eventEnable],
      BacnetEventTransitionBits.fromValue,
      _allTransitions,
    );
    final unacked = !_acked.toOffNormal || !_acked.toFault || !_acked.toNormal;
    if (_eventState == BacnetEventState.normal && !unacked) return null;
    final classNumber = properties[BacnetPropertyId.notificationClass]?.asInt;
    final notificationClass = classNumber == null
        ? null
        : device.object(BacnetObjectType.notificationClass, classNumber);
    final priorities = _decodeOr(
      notificationClass?[BacnetPropertyId.priority],
      BacnetEventPriorities.fromValue,
      const BacnetEventPriorities(
        toOffNormal: 255,
        toFault: 255,
        toNormal: 255,
      ),
    );
    return BacnetEventSummary(
      object: identifier,
      eventState: _eventState,
      acknowledgedTransitions: _acked,
      eventTimeStamps: List.unmodifiable(_stamps),
      notifyType: BacnetNotifyType(
        properties[BacnetPropertyId.notifyType]?.asInt ??
            BacnetNotifyType.alarm,
      ),
      eventEnable: enable,
      eventPriorities: [
        priorities.toOffNormal,
        priorities.toFault,
        priorities.toNormal,
      ],
    );
  }

  void _publishEventState() {
    properties[BacnetPropertyId.eventState] = BacnetEnumerated(_eventState);
    properties[BacnetPropertyId.ackedTransitions] = _acked.toValue();
    properties[BacnetPropertyId.eventTimeStamps] = BacnetList([
      for (final stamp in _stamps) stamp.toValue(),
    ]);
    properties[BacnetPropertyId.statusFlags] = BacnetStatusFlags(
      inAlarm: _eventState != BacnetEventState.normal,
      fault: _eventState == BacnetEventState.fault,
    ).toBitString();
  }

  static T _decodeOr<T>(
    BacnetValue? value,
    T Function(BacnetValue) decode,
    T fallback,
  ) {
    if (value == null) return fallback;
    try {
      return decode(value);
    } on BacnetDecodeException {
      return fallback;
    }
  }

  static bool _transitionBit(
    BacnetEventTransitionBits bits,
    BacnetEventTransition transition,
  ) => switch (transition) {
    BacnetEventTransition.toOffNormal => bits.toOffNormal,
    BacnetEventTransition.toFault => bits.toFault,
    BacnetEventTransition.toNormal => bits.toNormal,
  };

  static BacnetEventTransitionBits _withTransition(
    BacnetEventTransitionBits bits,
    BacnetEventTransition transition,
    bool value,
  ) => BacnetEventTransitionBits(
    toOffNormal: transition == BacnetEventTransition.toOffNormal
        ? value
        : bits.toOffNormal,
    toFault: transition == BacnetEventTransition.toFault ? value : bits.toFault,
    toNormal: transition == BacnetEventTransition.toNormal
        ? value
        : bits.toNormal,
  );

  void _publishPriorityArray() {
    properties[BacnetPropertyId.priorityArray] = BacnetList(
      List.unmodifiable(_priorityArray),
    );
  }

  /// Present value of a new object without one.
  static BacnetValue _defaultPresentValue(BacnetObjectType type) =>
      switch (type) {
        BacnetObjectType.analogInput ||
        BacnetObjectType.analogOutput ||
        BacnetObjectType.analogValue => const BacnetReal(0),
        BacnetObjectType.binaryInput ||
        BacnetObjectType.binaryOutput ||
        BacnetObjectType.binaryValue => const BacnetEnumerated(
          BacnetBinaryPV.inactive,
        ),
        BacnetObjectType.multiStateInput ||
        BacnetObjectType.multiStateOutput ||
        BacnetObjectType.multiStateValue => const BacnetUnsigned(1),
        BacnetObjectType.integerValue => const BacnetSigned(0),
        BacnetObjectType.positiveIntegerValue => const BacnetUnsigned(0),
        BacnetObjectType.characterStringValue => const BacnetCharacterString(
          '',
        ),
        _ => const BacnetNull(),
      };
}

/// An in-memory BACnet device for [FakeBacnetClient].
///
/// ```dart
/// final device = FakeBacnetDevice(1234, name: 'AHU-1')
///   ..addObject(
///     BacnetObjectType.analogInput,
///     1,
///     name: 'Supply Air Temperature',
///     presentValue: const BacnetReal(21.5),
///     units: BacnetEngineeringUnits.degreesCelsius,
///   );
/// final client = FakeBacnetClient(devices: [device]);
/// ```
final class FakeBacnetDevice {
  /// Creates a device with its Device object.
  FakeBacnetDevice(
    this.deviceId, {
    String? name,
    this.vendorId = 0,
    this.maxApdu = 1476,
    this.segmentation = BacnetSegmentation.both,
    String vendorName = 'bacnet_plugin',
    String modelName = 'FakeBacnetDevice',
  }) {
    final device = addObject(
      BacnetObjectType.device,
      deviceId,
      name: name ?? 'Device $deviceId',
    );
    device.properties.addAll({
      BacnetPropertyId.vendorIdentifier: BacnetUnsigned(vendorId),
      BacnetPropertyId.vendorName: BacnetCharacterString(vendorName),
      BacnetPropertyId.modelName: BacnetCharacterString(modelName),
      BacnetPropertyId.maxApduLengthAccepted: BacnetUnsigned(maxApdu),
      BacnetPropertyId.segmentationSupported: BacnetEnumerated(segmentation),
      BacnetPropertyId.protocolVersion: const BacnetUnsigned(1),
      BacnetPropertyId.protocolRevision: const BacnetUnsigned(22),
    });
  }

  /// Device instance.
  final int deviceId;

  /// Vendor identifier announced in I-Am.
  final int vendorId;

  /// Maximum APDU announced in I-Am.
  final int maxApdu;

  /// Segmentation support announced in I-Am.
  final BacnetSegmentation segmentation;

  /// While false, requests to the device time out and it ignores Who-Is.
  bool online = true;

  /// Communication state set by DeviceCommunicationControl: while
  /// disabled the device answers only DeviceCommunicationControl and
  /// ReinitializeDevice; while disabled or with initiation disabled it
  /// sends no COV or event notifications (and no I-Am while disabled).
  BacnetCommunicationState get communication => _communication;
  BacnetCommunicationState _communication = BacnetCommunicationState.enable;
  Timer? _communicationTimer;

  /// Password DeviceCommunicationControl and ReinitializeDevice require
  /// (null: none).
  String? password;

  /// ReinitializeDevice requests received, oldest first.
  final List<BacnetReinitializedState> reinitializations = [];

  /// Text messages received, oldest first.
  final List<TextMessageEvent> messages = [];

  /// Answers ConfirmedPrivateTransfer with its result block; without it
  /// the device rejects the service. Throw a [BacnetProtocolException]
  /// for an error answer.
  BacnetValue? Function(
    int vendorId,
    int serviceNumber,
    BacnetValue? parameters,
  )?
  onPrivateTransfer;

  /// Adds a File object with [content] (stream access).
  FakeBacnetObject addFile(
    int instance, {
    List<int> content = const [],
    String? name,
    String fileType = 'application/octet-stream',
    bool readOnly = false,
  }) => addObject(
    BacnetObjectType.file,
    instance,
    name: name,
    properties: {
      BacnetPropertyId.fileType: BacnetCharacterString(fileType),
      BacnetPropertyId.readOnly: BacnetBoolean(readOnly),
      BacnetPropertyId.fileAccessMethod: const BacnetEnumerated(
        BacnetFileAccessMethod.streamAccess,
      ),
    },
  )..fileContent = content;

  void _setCommunication(BacnetCommunicationState state, Duration? duration) {
    _communicationTimer?.cancel();
    _communication = state;
    if (duration != null && state != BacnetCommunicationState.enable) {
      _communicationTimer = Timer(
        duration,
        () => _communication = BacnetCommunicationState.enable,
      );
    }
  }

  /// Instances of the File objects of Configuration_Files: with files the
  /// device takes part in backup and restore (ReinitializeDevice
  /// START_BACKUP .. ABORT_RESTORE, Backup_And_Restore_State), without it
  /// refuses them.
  List<int> get configurationFiles => List.unmodifiable(_configurationFiles);
  List<int> _configurationFiles = const [];
  set configurationFiles(List<int> files) {
    _configurationFiles = List.of(files);
    final device = object(BacnetObjectType.device, deviceId)!;
    if (files.isEmpty) {
      device.properties
        ..remove(BacnetPropertyId.configurationFiles)
        ..remove(BacnetPropertyId.backupAndRestoreState);
      return;
    }
    device.properties[BacnetPropertyId.configurationFiles] = BacnetList([
      for (final file in files)
        BacnetObject(type: BacnetObjectType.file, instance: file),
    ]);
    _setBackupState(_backupState);
  }

  /// Backup_And_Restore_State.
  BacnetBackupState get backupState => _backupState;
  BacnetBackupState _backupState = BacnetBackupState.idle;

  /// Restores completed with ReinitializeDevice END_RESTORE.
  int restores = 0;

  void _setBackupState(BacnetBackupState state) {
    _backupState = state;
    object(
      BacnetObjectType.device,
      deviceId,
    )!.properties[BacnetPropertyId.backupAndRestoreState] = BacnetEnumerated(
      state,
    );
  }

  void _reinitialize(BacnetReinitializedState state) {
    final inProgress =
        _backupState != BacnetBackupState.idle &&
        _backupState != BacnetBackupState.backupFailure &&
        _backupState != BacnetBackupState.restoreFailure;
    switch (state) {
      case BacnetReinitializedState.startBackup ||
              BacnetReinitializedState.endBackup ||
              BacnetReinitializedState.startRestore ||
              BacnetReinitializedState.endRestore ||
              BacnetReinitializedState.abortRestore
          when _configurationFiles.isEmpty:
        throw _error(
          BacnetErrorClass.services,
          BacnetErrorCode.optionalFunctionalityNotSupported,
        );
      case BacnetReinitializedState.startBackup ||
              BacnetReinitializedState.startRestore
          when inProgress:
        throw _error(
          BacnetErrorClass.device,
          BacnetErrorCode.configurationInProgress,
        );
      case BacnetReinitializedState.startBackup:
        _setBackupState(BacnetBackupState.performingABackup);
      case BacnetReinitializedState.startRestore:
        _setBackupState(BacnetBackupState.performingARestore);
      case BacnetReinitializedState.endRestore:
        if (_backupState != BacnetBackupState.performingARestore) {
          throw _error(
            BacnetErrorClass.device,
            BacnetErrorCode.configurationInProgress,
          );
        }
        restores++;
        _setBackupState(BacnetBackupState.idle);
      case BacnetReinitializedState.endBackup ||
          BacnetReinitializedState.abortRestore:
        if (inProgress) _setBackupState(BacnetBackupState.idle);
    }
  }

  void _checkPassword(String? given) {
    if (password != null && given != password) {
      throw _error(BacnetErrorClass.security, BacnetErrorCode.passwordFailure);
    }
  }

  int _freeInstance(BacnetObjectType type) {
    var instance = 1;
    while (_objects.containsKey((type, instance))) {
      instance++;
    }
    return instance;
  }

  FakeBacnetObject _fileObject(int instance) {
    final file = _objects[(BacnetObjectType.file, instance)];
    if (file == null || file._file == null) {
      throw _error(BacnetErrorClass.object, BacnetErrorCode.unknownObject);
    }
    return file;
  }

  /// Services the device rejects as unrecognized, e.g.
  /// [BacnetConfirmedService.addListElement] to test the fallbacks of an
  /// application for devices that lack them.
  final Set<BacnetConfirmedService> unsupportedServices = {};

  /// Extra response time of this device.
  Duration latency = Duration.zero;

  final Map<(BacnetObjectType, int), FakeBacnetObject> _objects = {};
  final List<void Function(FakeBacnetObject, BacnetPropertyId)> _listeners = [];
  final List<void Function(EventNotificationEvent)> _eventListeners = [];

  /// Objects of the device, the Device object first.
  Iterable<FakeBacnetObject> get objects => _objects.values;

  /// Adds an object. Outputs are commandable unless [commandable] says
  /// otherwise; their [presentValue] becomes the relinquish default. Without
  /// [presentValue] the object starts at 0, inactive or state 1.
  FakeBacnetObject addObject(
    BacnetObjectType type,
    int instance, {
    String? name,
    BacnetValue? presentValue,
    BacnetEngineeringUnits? units,
    bool? commandable,
    Map<BacnetPropertyId, BacnetValue> properties = const {},
  }) {
    final object = FakeBacnetObject._(
      this,
      type,
      instance,
      commandable ??
          (type == BacnetObjectType.analogOutput ||
              type == BacnetObjectType.binaryOutput ||
              type == BacnetObjectType.multiStateOutput),
    );
    object.properties.addAll({
      BacnetPropertyId.objectIdentifier: object.identifier,
      BacnetPropertyId.objectName: BacnetCharacterString(
        name ?? '${type.label} $instance',
      ),
      BacnetPropertyId.objectType: BacnetEnumerated(type),
      if (units != null) BacnetPropertyId.units: BacnetEnumerated(units),
      ...properties,
    });
    if (type != BacnetObjectType.device) {
      final value = presentValue ?? FakeBacnetObject._defaultPresentValue(type);
      object.properties[BacnetPropertyId.presentValue] = value;
      if (object.commandable) {
        object.properties[BacnetPropertyId.relinquishDefault] = value;
        object._publishPriorityArray();
      }
    }
    _objects[(type, instance)] = object;
    return object;
  }

  /// The object [type]:[instance], or null.
  FakeBacnetObject? object(BacnetObjectType type, int instance) =>
      _objects[(type, instance)];

  /// Adds a Notification Class object. Clients receive the notifications
  /// of its objects after adding themselves to its Recipient_List
  /// ([FakeBacnetClient.addListElements]); every destination delivers one
  /// notification to the client.
  FakeBacnetObject addNotificationClass(
    int instance, {
    String? name,
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
  }) => addObject(
    BacnetObjectType.notificationClass,
    instance,
    name: name,
    properties: {
      BacnetPropertyId.notificationClass: BacnetUnsigned(instance),
      BacnetPropertyId.priority: priorities.toValue(),
      BacnetPropertyId.ackRequired: ackRequired.toValue(),
      BacnetPropertyId.recipientList: BacnetDestination.listToValue(recipients),
    },
  );

  void _notifyRecipients(
    EventNotificationEvent notification,
    BacnetEventTransition transition,
  ) {
    final recipients =
        _objects[(
          BacnetObjectType.notificationClass,
          notification.notificationClass,
        )]?[BacnetPropertyId.recipientList];
    if (recipients == null) return;
    final List<BacnetDestination> destinations;
    try {
      destinations = BacnetDestination.listFromValue(recipients);
    } on BacnetDecodeException {
      return;
    }
    for (final destination in destinations) {
      if (!FakeBacnetObject._transitionBit(
        destination.transitions,
        transition,
      )) {
        continue;
      }
      final delivered = EventNotificationEvent(
        processId: destination.processId,
        deviceId: notification.deviceId,
        object: notification.object,
        timeStamp: notification.timeStamp,
        notificationClass: notification.notificationClass,
        priority: notification.priority,
        eventType: notification.eventType,
        messageText: notification.messageText,
        notifyType: notification.notifyType,
        ackRequired: notification.ackRequired,
        fromState: notification.fromState,
        toState: notification.toState,
        eventValues: notification.eventValues,
        confirmed: destination.issueConfirmedNotifications,
      );
      for (final listener in List.of(_eventListeners)) {
        listener(delivered);
      }
    }
  }

  void _changed(FakeBacnetObject object, BacnetPropertyId property) {
    for (final listener in List.of(_listeners)) {
      listener(object, property);
    }
  }

  BacnetValue _read(BacnetObjectType type, int instance, BacnetPropertyId id) {
    final object = _objects[(type, instance)];
    if (object == null) {
      throw _error(BacnetErrorClass.object, BacnetErrorCode.unknownObject);
    }
    if (type == BacnetObjectType.device && id == BacnetPropertyId.objectList) {
      return BacnetList([for (final o in _objects.values) o.identifier]);
    }
    return object.properties[id] ??
        (throw _error(
          BacnetErrorClass.property,
          BacnetErrorCode.unknownProperty,
        ));
  }

  BacnetProtocolException _error(
    BacnetErrorClass c,
    BacnetErrorCode e, {
    int? firstFailedElement,
  }) => BacnetProtocolException(
    'device $deviceId returned an error',
    errorClass: c,
    errorCode: e,
    firstFailedElement: firstFailedElement,
  );
}

const BacnetEventTransitionBits _allTransitions = BacnetEventTransitionBits(
  toOffNormal: true,
  toFault: true,
  toNormal: true,
);

typedef _Subscription = ({
  int deviceId,
  BacnetObjectType type,
  int instance,
  BacnetPropertyId property,
  int processId,
  bool confirmed,
});

/// A router simulated by a [FakeBacnetClient]: answers
/// Who-Is-Router-To-Network with the [networks] it reaches and routing
/// table queries with [routingTable].
///
/// ```dart
/// final client = FakeBacnetClient(
///   routers: [FakeBacnetRouter('10.0.0.1', networks: [5, 6])],
///   networkNumber: 1,
/// );
/// final routers = await client.discoverRouters(); // 10.0.0.1 -> [5, 6]
/// ```
final class FakeBacnetRouter {
  /// Creates a router at [ipAddress] (an IPv4 address) and [port].
  ///
  /// The routing table defaults to one port per network.
  FakeBacnetRouter(
    this.ipAddress, {
    required List<int> networks,
    this.port = 47808,
    List<BacnetRoutingTableEntry>? routingTable,
  }) : networks = List.unmodifiable(networks),
       routingTable = List.unmodifiable(
         routingTable ??
             [
               for (final (index, network) in networks.indexed)
                 BacnetRoutingTableEntry(network: network, portId: index + 1),
             ],
       ),
       mac = List.unmodifiable([..._ipv4(ipAddress), port >> 8, port & 0xFF]) {
    RangeError.checkValueInInterval(port, 0, 0xFFFF, 'port');
  }

  static List<int> _ipv4(String ipAddress) {
    final octets = ipAddress.split('.').map(int.tryParse).toList();
    if (octets.length != 4 ||
        octets.any((o) => o == null || o < 0 || o > 255)) {
      throw ArgumentError.value(ipAddress, 'ipAddress', 'not an IPv4 address');
    }
    return octets.cast<int>();
  }

  /// IPv4 address.
  final String ipAddress;

  /// UDP port.
  final int port;

  /// The networks the router reaches.
  final List<int> networks;

  /// The answer to routing table queries.
  final List<BacnetRoutingTableEntry> routingTable;

  /// BACnet/IP address (IPv4 address and port).
  final List<int> mac;

  /// While false, the router ignores all messages.
  bool online = true;
}

/// A [BacnetClient] backed by in-memory [FakeBacnetDevice]s, for testing
/// applications without a network or the native stack.
///
/// It discovers devices (Who-Is/I-Am), reads and writes properties with the
/// errors real devices return, commands outputs through a priority array,
/// sends COV notifications for subscribed properties and can simulate
/// latency and offline devices. Every request is recorded in [requests].
///
/// ```dart
/// final ahu = FakeBacnetDevice(1234)
///   ..addObject(BacnetObjectType.analogValue, 1,
///       presentValue: const BacnetReal(21));
/// final client = FakeBacnetClient(devices: [ahu]);
/// await client.start();
///
/// final monitor = PropertyMonitor(client);
/// final updates = monitor.monitorPresentValue(
///   1234,
///   const BacnetObject(type: BacnetObjectType.analogValue, instance: 1),
/// );
/// ahu.object(BacnetObjectType.analogValue, 1)![BacnetPropertyId.presentValue] =
///     const BacnetReal(22.5); // delivered as a COV notification
/// ```
class FakeBacnetClient implements BacnetClient {
  /// Creates a client serving [devices].
  FakeBacnetClient({
    Iterable<FakeBacnetDevice> devices = const [],
    Iterable<FakeBacnetRouter> routers = const [],
    this.networkNumber,
    this.latency = Duration.zero,
    BacnetConfig config = const BacnetConfig(),
  }) : _config = config,
       routers = List.of(routers) {
    devices.forEach(addDevice);
  }

  final BacnetConfig _config;
  final Map<int, FakeBacnetDevice> _devices = {};
  final Set<int> _bound = {};
  final List<_Subscription> _subscriptions = [];
  final StreamController<BacnetEvent> _events =
      StreamController<BacnetEvent>.broadcast();
  bool _started = false;
  int _nextProcessId = 1;
  int _completed = 0;
  int _failed = 0;
  int _timeouts = 0;

  /// Response time of every request.
  Duration latency;

  /// Requests received, oldest first.
  final List<FakeBacnetRequest> requests = [];

  /// Routers of the simulated network.
  final List<FakeBacnetRouter> routers;

  /// Number of the local network: the first online router answers
  /// What-Is-Network-Number with it (null: nobody answers).
  int? networkNumber;

  /// Devices served by this client.
  Map<int, FakeBacnetDevice> get devices => Map.unmodifiable(_devices);

  /// Adds a device; it answers Who-Is and requests.
  void addDevice(FakeBacnetDevice device) {
    _devices[device.deviceId] = device;
    device._listeners.add(
      (object, property) => _notify(device, object, property),
    );
    device._eventListeners.add((notification) {
      if (device.communication != BacnetCommunicationState.enable) return;
      unawaited(
        Future<void>.delayed(latency + device.latency, () {
          if (!_events.isClosed) _events.add(notification);
        }),
      );
    });
  }

  @override
  BacnetConfig get config => _config;

  @override
  Stream<BacnetEvent> get events => _events.stream;

  @override
  Stream<IAmEvent> get iAmEvents =>
      events.where((e) => e is IAmEvent).cast<IAmEvent>();

  @override
  Stream<CovNotificationEvent> get covEvents => events
      .where((e) => e is CovNotificationEvent)
      .cast<CovNotificationEvent>();

  @override
  Stream<EventNotificationEvent> get eventNotifications => events
      .where((e) => e is EventNotificationEvent)
      .cast<EventNotificationEvent>();

  @override
  Stream<WhoAmIEvent> get whoAmIRequests =>
      events.where((e) => e is WhoAmIEvent).cast<WhoAmIEvent>();

  /// Delivers [event] to the listeners as if the network produced it, e.g.
  /// a [WhoAmIEvent] of a new device.
  void receive(BacnetEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<void> sendYouAre({
    required int vendorId,
    required String modelName,
    required String serialNumber,
    int? deviceId,
    List<int>? macAddress,
    BacnetAddressRecipient? destination,
    int network = 0xFFFF,
  }) async {
    _checkStarted();
    // validates like the real client
    encodeYouAre(
      vendorId: vendorId,
      modelName: modelName,
      serialNumber: serialNumber,
      deviceId: deviceId,
      macAddress: macAddress,
    );
    requests.add(
      FakeBacnetRequest(
        'sendYouAre',
        deviceId: deviceId,
        arguments: {
          'vendorId': vendorId,
          'modelName': modelName,
          'serialNumber': serialNumber,
          'macAddress': ?macAddress,
          'destination': ?destination,
        },
      ),
    );
  }

  @override
  Future<void> writeGroup(
    int groupNumber,
    List<BacnetGroupChannelValue> changes, {
    int writePriority = 16,
    bool? inhibitDelay,
    int? deviceId,
    int network = 0xFFFF,
  }) async {
    _checkStarted();
    encodeWriteGroup(
      groupNumber,
      changes,
      writePriority: writePriority,
      inhibitDelay: inhibitDelay,
    );
    requests.add(
      FakeBacnetRequest(
        'writeGroup',
        deviceId: deviceId,
        priority: writePriority,
        arguments: {
          'groupNumber': groupNumber,
          'changes': List<BacnetGroupChannelValue>.unmodifiable(changes),
          'inhibitDelay': ?inhibitDelay,
        },
      ),
    );
  }

  @override
  Stream<NetworkMessageEvent> get networkMessages =>
      events.where((e) => e is NetworkMessageEvent).cast<NetworkMessageEvent>();

  @override
  String? get nativeVersion => _started ? 'fake' : null;

  @override
  void log(
    BacnetLogLevel level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    _config.logger.log(level, message, error, stackTrace);
  }

  @override
  Future<void> start({String? interface, int? port}) async {
    _started = true;
  }

  @override
  Future<void> close() async {
    _started = false;
  }

  @override
  void dispose() => _started = false;

  @override
  int allocateProcessId() {
    final id = _nextProcessId;
    _nextProcessId = _nextProcessId >= 0x3FFFFF ? 1 : _nextProcessId + 1;
    return id;
  }

  @override
  Future<void> sendWhoIs({
    int lowLimit = -1,
    int highLimit = -1,
    int network = 0xFFFF,
  }) async {
    _checkStarted();
    requests.add(const FakeBacnetRequest('sendWhoIs'));
    for (final device in _devices.values) {
      final id = device.deviceId;
      if (!device.online ||
          device.communication == BacnetCommunicationState.disable ||
          (lowLimit >= 0 && id < lowLimit) ||
          (highLimit >= 0 && id > highLimit)) {
        continue;
      }
      _bound.add(id);
      unawaited(
        Future<void>.delayed(latency + device.latency, () {
          if (_events.isClosed) return;
          _events.add(
            IAmEvent(
              deviceId: id,
              net: 0,
              mac: [10, 0, (id >> 8) & 0xFF, id & 0xFF, 0xBA, 0xC0],
              len: 0,
              maxApdu: device.maxApdu,
              vendorId: device.vendorId,
              segmentation: device.segmentation,
            ),
          );
        }),
      );
    }
  }

  @override
  Future<void> sendWhoHas({
    BacnetObject? object,
    String? objectName,
    int lowLimit = -1,
    int highLimit = -1,
    int network = 0xFFFF,
  }) async {
    _checkStarted();
    if ((object == null) == (objectName == null)) {
      throw ArgumentError('give either object or objectName');
    }
    requests.add(
      FakeBacnetRequest('sendWhoHas', object: object, objectName: objectName),
    );
    for (final device in _devices.values) {
      final id = device.deviceId;
      if (!device.online ||
          (lowLimit >= 0 && id < lowLimit) ||
          (highLimit >= 0 && id > highLimit)) {
        continue;
      }
      for (final candidate in device.objects) {
        final name =
            candidate.properties[BacnetPropertyId.objectName]?.asString ?? '';
        if (candidate.identifier != object && name != objectName) continue;
        unawaited(
          Future<void>.delayed(latency + device.latency, () {
            if (_events.isClosed) return;
            _events.add(
              IHaveEvent(
                deviceId: id,
                object: candidate.identifier,
                objectName: name,
              ),
            );
          }),
        );
      }
    }
  }

  @override
  Future<BacnetValue> readProperty(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId, {
    int arrayIndex = -1,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(
      FakeBacnetRequest(
        'readProperty',
        deviceId: deviceId,
        object: BacnetObject(type: objectType, instance: instance),
        propertyId: propertyId,
      ),
    );
    return _request(
      BacnetConfirmedService.readProperty,
      deviceId,
      cancelToken,
      (device) {
        final value = device._read(objectType, instance, propertyId);
        if (arrayIndex < 0) return value;
        if (value is! BacnetList) {
          throw device._error(
            BacnetErrorClass.property,
            BacnetErrorCode.propertyIsNotAnArray,
          );
        }
        if (arrayIndex == 0) return BacnetUnsigned(value.length);
        if (arrayIndex > value.length) {
          throw device._error(
            BacnetErrorClass.property,
            BacnetErrorCode.invalidArrayIndex,
          );
        }
        return value[arrayIndex - 1];
      },
    );
  }

  @override
  Future<T> read<T>(
    int deviceId,
    BacnetObject object,
    BacnetProperty<T> property, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => readProperty(
    deviceId,
    object.type,
    object.instance,
    property.id,
    cancelToken: cancelToken,
  ).then(property.decode);

  @override
  Future<void> write<T>(
    int deviceId,
    BacnetObject object,
    BacnetWritableProperty<T> property,
    T value, {
    int priority = 16,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => Future.sync(
    () => writeProperty(
      deviceId,
      object.type,
      object.instance,
      property.id,
      property.encodeValue(value),
      priority: priority,
      cancelToken: cancelToken,
    ),
  );

  @override
  Future<Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>>
  readMultiple(
    int deviceId,
    List<BacnetReadAccessSpecification> specs, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(FakeBacnetRequest('readMultiple', deviceId: deviceId));
    if (specs.isEmpty) return Future.value(const {});
    checkUniqueProperties(specs);
    return _request(
      BacnetConfirmedService.readPropertyMultiple,
      deviceId,
      cancelToken,
      (device) {
        final result =
            <BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>{};
        for (final spec in specs) {
          final properties = result[spec.objectIdentifier] ??= {};
          for (final reference in spec.properties) {
            properties[reference.propertyIdentifier] = _readOrError(
              device,
              spec.objectIdentifier,
              reference.propertyIdentifier,
            );
          }
        }
        return result;
      },
    );
  }

  static BacnetPropertyResult _readOrError(
    FakeBacnetDevice device,
    BacnetObject object,
    BacnetPropertyId property,
  ) {
    try {
      return device._read(object.type, object.instance, property);
    } on BacnetProtocolException catch (e) {
      return BacnetError(e.errorClass, e.errorCode);
    }
  }

  @override
  Future<void> writeProperty(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId,
    BacnetValue value, {
    int priority = 16,
    int arrayIndex = -1,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(
      FakeBacnetRequest(
        'writeProperty',
        deviceId: deviceId,
        object: BacnetObject(type: objectType, instance: instance),
        propertyId: propertyId,
        value: value,
        priority: priority,
      ),
    );
    return _request(
      BacnetConfirmedService.writeProperty,
      deviceId,
      cancelToken,
      (device) {
        _write(device, objectType, instance, propertyId, value, priority);
      },
    );
  }

  @override
  Future<void> writeMultiple(
    int deviceId,
    List<BacnetWriteAccessSpecification> specs, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(FakeBacnetRequest('writeMultiple', deviceId: deviceId));
    return _request(
      BacnetConfirmedService.writePropertyMultiple,
      deviceId,
      cancelToken,
      (device) {
        for (final spec in specs) {
          for (final property in spec.listOfProperties) {
            _write(
              device,
              spec.objectIdentifier.type,
              spec.objectIdentifier.instance,
              property.propertyIdentifier,
              property.value,
              property.priority,
            );
          }
        }
      },
    );
  }

  void _write(
    FakeBacnetDevice device,
    BacnetObjectType type,
    int instance,
    BacnetPropertyId property,
    BacnetValue value,
    int priority,
  ) {
    final object = device.object(type, instance);
    if (object == null) {
      throw device._error(
        BacnetErrorClass.object,
        BacnetErrorCode.unknownObject,
      );
    }
    if (!object.properties.containsKey(property)) {
      throw device._error(
        BacnetErrorClass.property,
        BacnetErrorCode.unknownProperty,
      );
    }
    object._write(property, value, priority);
  }

  @override
  Future<void> subscribeCOV(
    int deviceId,
    BacnetObjectType objectType,
    int instance, {
    BacnetPropertyId propId = BacnetPropertyId.presentValue,
    int processId = 1,
    Duration lifetime = const Duration(minutes: 5),
    bool confirmed = false,
    double? covIncrement,
    Duration? timeout,
  }) {
    requests.add(
      FakeBacnetRequest(
        'subscribeCOV',
        deviceId: deviceId,
        object: BacnetObject(type: objectType, instance: instance),
        propertyId: propId,
      ),
    );
    return _request(BacnetConfirmedService.subscribeCov, deviceId, null, (
      device,
    ) {
      device._read(objectType, instance, propId);
      _subscriptions
        ..removeWhere(
          (s) => _same(s, deviceId, objectType, instance, propId, processId),
        )
        ..add((
          deviceId: deviceId,
          type: objectType,
          instance: instance,
          property: propId,
          processId: processId,
          confirmed: confirmed,
        ));
    });
  }

  @override
  Future<void> unsubscribeCOV(
    int deviceId,
    BacnetObjectType objectType,
    int instance, {
    BacnetPropertyId propId = BacnetPropertyId.presentValue,
    int processId = 1,
    Duration? timeout,
  }) {
    requests.add(
      FakeBacnetRequest(
        'unsubscribeCOV',
        deviceId: deviceId,
        object: BacnetObject(type: objectType, instance: instance),
        propertyId: propId,
      ),
    );
    return _request(BacnetConfirmedService.subscribeCov, deviceId, null, (_) {
      _subscriptions.removeWhere(
        (s) => _same(s, deviceId, objectType, instance, propId, processId),
      );
    });
  }

  static bool _same(
    _Subscription s,
    int deviceId,
    BacnetObjectType type,
    int instance,
    BacnetPropertyId property,
    int processId,
  ) =>
      s.deviceId == deviceId &&
      s.type == type &&
      s.instance == instance &&
      s.property == property &&
      s.processId == processId;

  void _notify(
    FakeBacnetDevice device,
    FakeBacnetObject object,
    BacnetPropertyId property,
  ) {
    if (device.communication != BacnetCommunicationState.enable) return;
    for (final s in _subscriptions) {
      if (s.deviceId != device.deviceId ||
          s.type != object.type ||
          s.instance != object.instance ||
          s.property != property) {
        continue;
      }
      final value = object.properties[property];
      if (value == null) continue;
      final values = <BacnetPropertyId, BacnetValue>{
        property: value,
        BacnetPropertyId.statusFlags:
            ?object.properties[BacnetPropertyId.statusFlags],
      };
      final event = CovNotificationEvent(
        objectType: object.type,
        instance: object.instance,
        timestamp: DateTime.now().toIso8601String(),
        deviceId: device.deviceId,
        subscriberProcessId: s.processId,
        values: values,
        confirmed: s.confirmed,
      );
      unawaited(
        Future<void>.delayed(latency + device.latency, () {
          if (!_events.isClosed) _events.add(event);
        }),
      );
    }
  }

  @override
  Future<List<BacnetObject>> scanDevice(
    int deviceId, {
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) async {
    final list = await readProperty(
      deviceId,
      BacnetObjectType.device,
      deviceId,
      BacnetPropertyId.objectList,
      cancelToken: cancelToken,
    );
    return list.asList.whereType<BacnetObject>().toList();
  }

  @override
  Future<TrendLogData> getTrendLog(
    int deviceId,
    int instance, {
    BacnetPropertyId logBufferPropId = BacnetPropertyId.logBuffer,
    int count = 100,
    int? fromSequenceNumber,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(
      FakeBacnetRequest(
        'getTrendLog',
        deviceId: deviceId,
        object: BacnetObject(
          type: BacnetObjectType.trendLog,
          instance: instance,
        ),
      ),
    );
    return _request(BacnetConfirmedService.readRange, deviceId, cancelToken, (
      device,
    ) {
      final object = device.object(BacnetObjectType.trendLog, instance);
      if (object == null) {
        throw device._error(
          BacnetErrorClass.object,
          BacnetErrorCode.unknownObject,
        );
      }
      final records = object.records;
      final start = fromSequenceNumber != null
          ? (fromSequenceNumber - 1).clamp(0, records.length)
          : (records.length - count).clamp(0, records.length);
      final entries = records.skip(start).take(count).toList();
      return TrendLogData(
        itemCount: entries.length,
        totalRecords: records.length,
        entries: entries,
      );
    });
  }

  @override
  Future<void> addListElement(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId,
    BacnetValue elements, {
    int arrayIndex = -1,
    Duration? timeout,
  }) {
    requests.add(
      FakeBacnetRequest(
        'addListElement',
        deviceId: deviceId,
        object: BacnetObject(type: objectType, instance: instance),
        propertyId: propertyId,
        value: elements,
      ),
    );
    return _request(BacnetConfirmedService.addListElement, deviceId, null, (
      device,
    ) {
      final object = _listObject(device, objectType, instance, propertyId);
      final current = _listElements(object, propertyId, object[propertyId]!);
      final added = _listElements(object, propertyId, elements);
      object[propertyId] = _listValue(propertyId, [
        ...current,
        ...added.where((e) => !current.contains(e)),
      ]);
    });
  }

  @override
  Future<void> removeListElement(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId,
    BacnetValue elements, {
    int arrayIndex = -1,
    Duration? timeout,
  }) {
    requests.add(
      FakeBacnetRequest(
        'removeListElement',
        deviceId: deviceId,
        object: BacnetObject(type: objectType, instance: instance),
        propertyId: propertyId,
        value: elements,
      ),
    );
    return _request(BacnetConfirmedService.removeListElement, deviceId, null, (
      device,
    ) {
      final object = _listObject(device, objectType, instance, propertyId);
      final current = _listElements(object, propertyId, object[propertyId]!);
      final removed = _listElements(object, propertyId, elements);
      if (removed.any((e) => !current.contains(e))) {
        throw device._error(
          BacnetErrorClass.services,
          BacnetErrorCode.listElementNotFound,
        );
      }
      object[propertyId] = _listValue(propertyId, [
        ...current.where((e) => !removed.contains(e)),
      ]);
    });
  }

  @override
  Future<void> addListElements<E>(
    int deviceId,
    BacnetObject object,
    BacnetWritableProperty<List<E>> property,
    List<E> elements, {
    Duration? timeout,
  }) => Future.sync(
    () => addListElement(
      deviceId,
      object.type,
      object.instance,
      property.id,
      property.encodeValue(elements),
    ),
  );

  @override
  Future<void> removeListElements<E>(
    int deviceId,
    BacnetObject object,
    BacnetWritableProperty<List<E>> property,
    List<E> elements, {
    Duration? timeout,
  }) => Future.sync(
    () => removeListElement(
      deviceId,
      object.type,
      object.instance,
      property.id,
      property.encodeValue(elements),
    ),
  );

  static FakeBacnetObject _listObject(
    FakeBacnetDevice device,
    BacnetObjectType type,
    int instance,
    BacnetPropertyId property,
  ) {
    final object = device.object(type, instance);
    if (object == null) {
      throw device._error(
        BacnetErrorClass.object,
        BacnetErrorCode.unknownObject,
      );
    }
    if (object[property] == null) {
      throw device._error(
        BacnetErrorClass.property,
        BacnetErrorCode.unknownProperty,
      );
    }
    return object;
  }

  /// The elements of a list: destinations of a Recipient_List, the values
  /// of any other list.
  static List<Object> _listElements(
    FakeBacnetObject object,
    BacnetPropertyId property,
    BacnetValue value,
  ) {
    if (property != BacnetPropertyId.recipientList) return value.asList;
    try {
      return BacnetDestination.listFromValue(value);
    } on BacnetDecodeException {
      throw object.device._error(
        BacnetErrorClass.property,
        BacnetErrorCode.invalidDataType,
      );
    }
  }

  static BacnetValue _listValue(
    BacnetPropertyId property,
    List<Object> elements,
  ) => property == BacnetPropertyId.recipientList
      ? BacnetDestination.listToValue(elements.cast<BacnetDestination>())
      : BacnetList(List.unmodifiable(elements.cast<BacnetValue>()));

  @override
  Future<void> acknowledgeAlarm(
    int deviceId,
    BacnetObject object,
    BacnetEventState eventState,
    BacnetTimeStamp timeStamp, {
    required String source,
    int processId = 0,
    DateTime? time,
    Duration? timeout,
  }) {
    requests.add(
      FakeBacnetRequest(
        'acknowledgeAlarm',
        deviceId: deviceId,
        object: object,
        value: BacnetEnumerated(eventState),
        time: time,
        source: source,
      ),
    );
    return _request(BacnetConfirmedService.acknowledgeAlarm, deviceId, null, (
      device,
    ) {
      final target = device.object(object.type, object.instance);
      if (target == null) {
        throw device._error(
          BacnetErrorClass.object,
          BacnetErrorCode.unknownObject,
        );
      }
      target._acknowledge(eventState, timeStamp);
    });
  }

  @override
  Future<void> acknowledgeEvent(
    EventNotificationEvent notification, {
    required String source,
    DateTime? time,
    Duration? timeout,
  }) => acknowledgeAlarm(
    notification.deviceId,
    notification.object,
    notification.toState,
    notification.timeStamp,
    source: source,
    processId: notification.processId,
    time: time,
  );

  @override
  Future<List<BacnetEventSummary>> getEventInformation(
    int deviceId, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(FakeBacnetRequest('getEventInformation', deviceId: deviceId));
    return _request(
      BacnetConfirmedService.getEventInformation,
      deviceId,
      cancelToken,
      (device) => List.unmodifiable(
        device.objects.map((o) => o._eventSummary).nonNulls,
      ),
    );
  }

  @override
  Future<List<BacnetAlarmSummary>> getAlarmSummary(
    int deviceId, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(FakeBacnetRequest('getAlarmSummary', deviceId: deviceId));
    return _request(
      BacnetConfirmedService.getAlarmSummary,
      deviceId,
      cancelToken,
      (device) => List.unmodifiable([
        for (final summary in device.objects.map((o) => o._eventSummary))
          if (summary != null &&
              summary.eventState != BacnetEventState.normal &&
              summary.notifyType == BacnetNotifyType.alarm)
            BacnetAlarmSummary(
              object: summary.object,
              alarmState: summary.eventState,
              acknowledgedTransitions: summary.acknowledgedTransitions,
            ),
      ]),
    );
  }

  // ---- device management ----------------------------------------------------

  @override
  Future<void> deviceCommunicationControl(
    int deviceId,
    BacnetCommunicationState state, {
    Duration? duration,
    String? password,
    Duration? timeout,
  }) {
    requests.add(
      FakeBacnetRequest(
        'deviceCommunicationControl',
        deviceId: deviceId,
        value: BacnetEnumerated(state),
      ),
    );
    return _request(
      BacnetConfirmedService.deviceCommunicationControl,
      deviceId,
      null,
      (device) {
        device
          .._checkPassword(password)
          .._setCommunication(state, duration);
      },
    );
  }

  @override
  Future<void> reinitializeDevice(
    int deviceId,
    BacnetReinitializedState state, {
    String? password,
    Duration? timeout,
  }) {
    requests.add(
      FakeBacnetRequest(
        'reinitializeDevice',
        deviceId: deviceId,
        value: BacnetEnumerated(state),
      ),
    );
    return _request(BacnetConfirmedService.reinitializeDevice, deviceId, null, (
      device,
    ) {
      device
        .._checkPassword(password)
        .._reinitialize(state)
        ..reinitializations.add(state);
    });
  }

  @override
  Future<BacnetObject> createObject(
    int deviceId, {
    BacnetObjectType? type,
    BacnetObject? object,
    List<BacnetPropertyValue> initialValues = const [],
    Duration? timeout,
  }) => Future.sync(() {
    if ((type == null) == (object == null)) {
      throw ArgumentError('give either type or object');
    }
    requests.add(
      FakeBacnetRequest('createObject', deviceId: deviceId, object: object),
    );
    return _request(BacnetConfirmedService.createObject, deviceId, null, (
      device,
    ) {
      final objectType = object?.type ?? type!;
      if (objectType == BacnetObjectType.device) {
        throw device._error(
          BacnetErrorClass.object,
          BacnetErrorCode.dynamicCreationNotSupported,
          firstFailedElement: 0,
        );
      }
      final instance = object?.instance ?? device._freeInstance(objectType);
      if (device.object(objectType, instance) != null) {
        throw device._error(
          BacnetErrorClass.object,
          BacnetErrorCode.objectIdentifierAlreadyExists,
          firstFailedElement: 0,
        );
      }
      for (final (index, value) in initialValues.indexed) {
        if (value.propertyIdentifier == BacnetPropertyId.objectIdentifier ||
            value.propertyIdentifier == BacnetPropertyId.objectType) {
          throw device._error(
            BacnetErrorClass.property,
            BacnetErrorCode.writeAccessDenied,
            firstFailedElement: index + 1,
          );
        }
      }
      final created = device.addObject(objectType, instance);
      for (final value in initialValues) {
        created._write(value.propertyIdentifier, value.value, value.priority);
      }
      return created.identifier;
    });
  });

  @override
  Future<void> deleteObject(
    int deviceId,
    BacnetObject object, {
    Duration? timeout,
  }) {
    requests.add(
      FakeBacnetRequest('deleteObject', deviceId: deviceId, object: object),
    );
    return _request(BacnetConfirmedService.deleteObject, deviceId, null, (
      device,
    ) {
      if (object.type == BacnetObjectType.device) {
        throw device._error(
          BacnetErrorClass.object,
          BacnetErrorCode.objectDeletionNotPermitted,
        );
      }
      if (device._objects.remove((object.type, object.instance)) == null) {
        throw device._error(
          BacnetErrorClass.object,
          BacnetErrorCode.unknownObject,
        );
      }
    });
  }

  @override
  Future<int?> deviceMaxApdu(int deviceId) async =>
      _bound.contains(deviceId) ? _devices[deviceId]?.maxApdu : null;

  // ---- files ----------------------------------------------------------------

  BacnetObject _file(int instance) =>
      BacnetObject(type: BacnetObjectType.file, instance: instance);

  @override
  Future<BacnetFileChunk> readFileStream(
    int deviceId,
    int fileInstance, {
    required int start,
    required int count,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(
      FakeBacnetRequest(
        'readFileStream',
        deviceId: deviceId,
        object: _file(fileInstance),
      ),
    );
    return _request(
      BacnetConfirmedService.atomicReadFile,
      deviceId,
      cancelToken,
      (device) {
        final content = device._fileObject(fileInstance)._file!;
        if (start < 0 || start > content.length || count < 0) {
          throw device._error(
            BacnetErrorClass.services,
            BacnetErrorCode.invalidFileStartPosition,
          );
        }
        final end = start + count < content.length
            ? start + count
            : content.length;
        return BacnetFileChunk(
          start: start,
          data: content.sublist(start, end),
          endOfFile: end >= content.length,
        );
      },
    );
  }

  @override
  Future<BacnetFileRecords> readFileRecords(
    int deviceId,
    int fileInstance, {
    required int start,
    required int count,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => _recordAccess(deviceId, fileInstance, 'readFileRecords', cancelToken);

  @override
  Future<int> writeFileStream(
    int deviceId,
    int fileInstance,
    List<int> data, {
    int start = 0,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) {
    requests.add(
      FakeBacnetRequest(
        'writeFileStream',
        deviceId: deviceId,
        object: _file(fileInstance),
        value: BacnetOctetString(Uint8List.fromList(data)),
      ),
    );
    return _request(
      BacnetConfirmedService.atomicWriteFile,
      deviceId,
      cancelToken,
      (device) {
        final file = device._fileObject(fileInstance);
        if (file.properties[BacnetPropertyId.readOnly]?.asBool ?? false) {
          throw device._error(
            BacnetErrorClass.services,
            BacnetErrorCode.fileAccessDenied,
          );
        }
        final content = file._file!;
        final position = start == -1 ? content.length : start;
        if (position < 0 || position > content.length) {
          throw device._error(
            BacnetErrorClass.services,
            BacnetErrorCode.invalidFileStartPosition,
          );
        }
        file.fileContent = [
          ...content.take(position),
          ...data,
          ...content.skip(position + data.length),
        ];
        return position;
      },
    );
  }

  @override
  Future<int> writeFileRecords(
    int deviceId,
    int fileInstance,
    List<List<int>> records, {
    int start = 0,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => _recordAccess(deviceId, fileInstance, 'writeFileRecords', cancelToken);

  /// Fake files have stream access only.
  Future<T> _recordAccess<T>(
    int deviceId,
    int fileInstance,
    String service,
    BacnetCancelToken? cancelToken,
  ) {
    requests.add(
      FakeBacnetRequest(
        service,
        deviceId: deviceId,
        object: _file(fileInstance),
      ),
    );
    return _request(
      service == 'readFileRecords'
          ? BacnetConfirmedService.atomicReadFile
          : BacnetConfirmedService.atomicWriteFile,
      deviceId,
      cancelToken,
      (device) {
        device._fileObject(fileInstance);
        throw device._error(
          BacnetErrorClass.services,
          BacnetErrorCode.invalidFileAccessMethod,
        );
      },
    );
  }

  // ---- vendor services and messages -----------------------------------------

  @override
  Future<BacnetValue?> privateTransfer(
    int deviceId,
    int vendorId,
    int serviceNumber, {
    BacnetValue? parameters,
    Duration? timeout,
  }) {
    requests.add(
      FakeBacnetRequest(
        'privateTransfer',
        deviceId: deviceId,
        value: parameters,
      ),
    );
    return _request(BacnetConfirmedService.privateTransfer, deviceId, null, (
      device,
    ) {
      final handler = device.onPrivateTransfer;
      if (handler == null) {
        throw BacnetRejectException(
          'device $deviceId rejected the request',
          reason: BacnetRejectReason.unrecognizedService,
        );
      }
      return handler(vendorId, serviceNumber, parameters);
    });
  }

  @override
  Future<void> sendPrivateTransfer(
    int vendorId,
    int serviceNumber, {
    BacnetValue? parameters,
    int? deviceId,
    int network = 0xFFFF,
  }) async {
    _checkStarted();
    requests.add(
      FakeBacnetRequest(
        'sendPrivateTransfer',
        deviceId: deviceId,
        value: parameters,
      ),
    );
  }

  TextMessageEvent _message(
    String message,
    bool urgent,
    int? classNumber,
    String? classText,
  ) {
    if (classNumber != null && classText != null) {
      throw ArgumentError('give at most one of classNumber and classText');
    }
    return TextMessageEvent(
      sourceDeviceId: _config.deviceInstance,
      message: message,
      urgent: urgent,
      classNumber: classNumber,
      classText: classText,
    );
  }

  @override
  Future<void> textMessage(
    int deviceId,
    String message, {
    bool urgent = false,
    int? classNumber,
    String? classText,
    Duration? timeout,
  }) => Future.sync(() {
    final event = _message(message, urgent, classNumber, classText);
    requests.add(
      FakeBacnetRequest(
        'textMessage',
        deviceId: deviceId,
        value: BacnetCharacterString(message),
      ),
    );
    return _request(BacnetConfirmedService.textMessage, deviceId, null, (
      device,
    ) {
      device.messages.add(event);
    });
  });

  @override
  Future<void> sendTextMessage(
    String message, {
    int? deviceId,
    int network = 0xFFFF,
    bool urgent = false,
    int? classNumber,
    String? classText,
  }) async {
    _checkStarted();
    final event = _message(message, urgent, classNumber, classText);
    requests.add(
      FakeBacnetRequest(
        'sendTextMessage',
        deviceId: deviceId,
        value: BacnetCharacterString(message),
      ),
    );
    for (final device in _devices.values) {
      if ((deviceId == null || device.deviceId == deviceId) &&
          device.online &&
          device.communication != BacnetCommunicationState.disable) {
        device.messages.add(event);
      }
    }
  }

  @override
  Future<ReadRangeResult> readRange(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId, {
    BacnetRange range = const BacnetRange.all(),
    int arrayIndex = -1,
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => _unsupported(deviceId, 'readRange');

  @override
  Future<Uint8List> sendConfirmedRaw(
    int deviceId,
    BacnetConfirmedService service,
    Uint8List serviceData, {
    Duration? timeout,
    bool background = false,
    BacnetCancelToken? cancelToken,
  }) => _unsupported(deviceId, 'sendConfirmedRaw');

  Future<T> _unsupported<T>(int deviceId, String service) {
    requests.add(FakeBacnetRequest(service, deviceId: deviceId));
    return _request(
      null,
      deviceId,
      null,
      (_) => throw BacnetRejectException(
        'device $deviceId rejected the request',
        reason: BacnetRejectReason.unrecognizedService,
      ),
    );
  }

  @override
  Future<void> timeSynchronization(
    DateTime time, {
    bool utc = false,
    int? deviceId,
  }) async {
    _checkStarted();
    requests.add(
      FakeBacnetRequest('timeSynchronization', deviceId: deviceId, time: time),
    );
  }

  @override
  Future<void> registerForeignDevice(
    String ip, {
    int port = 47808,
    int ttl = 120,
  }) async {
    _checkStarted();
    requests.add(
      FakeBacnetRequest('registerForeignDevice', address: '$ip:$port'),
    );
  }

  @override
  Future<void> addDeviceBinding(
    int deviceId,
    String ip, {
    int port = 47808,
    int network = 0,
    List<int> adr = const [],
    int maxApdu = 1476,
  }) async {
    _checkStarted();
    _bound.add(deviceId);
  }

  @override
  Future<void> removeDeviceBinding(int deviceId) async {
    _bound.remove(deviceId);
  }

  @override
  Future<bool> isDeviceBound(int deviceId) async => _bound.contains(deviceId);

  /// Simulates the [routers]: they answer Who-Is-Router-To-Network,
  /// What-Is-Network-Number (with [networkNumber]) and routing table
  /// queries (an Initialize-Routing-Table without entries sent to them).
  @override
  Future<void> sendNetworkMessage(
    BacnetNetworkMessage message, {
    String? ip,
    int port = 47808,
    int network = 0,
    List<int> adr = const [],
  }) async {
    _checkStarted();
    requests.add(
      FakeBacnetRequest(
        'sendNetworkMessage',
        address: ip == null ? null : '$ip:$port',
        networkMessage: message,
      ),
    );
    if (network != 0 && network != 0xFFFF) return;
    for (final router in routers) {
      if (!router.online ||
          (ip != null && (router.ipAddress != ip || router.port != port))) {
        continue;
      }
      final answer = switch (message) {
        BacnetWhoIsRouterToNetwork(network: null) => BacnetIAmRouterToNetwork(
          router.networks,
        ),
        BacnetWhoIsRouterToNetwork(:final network?)
            when router.networks.contains(network) =>
          BacnetIAmRouterToNetwork([network]),
        BacnetWhatIsNetworkNumber() when networkNumber != null =>
          BacnetNetworkNumberIs(network: networkNumber!, configured: true),
        BacnetInitializeRoutingTable(entries: []) when ip != null =>
          BacnetInitializeRoutingTableAck(router.routingTable),
        _ => null,
      };
      if (answer == null) continue;
      unawaited(
        Future<void>.delayed(latency, () {
          if (_events.isClosed) return;
          _events.add(NetworkMessageEvent(message: answer, mac: router.mac));
        }),
      );
      // one device tells the network number
      if (answer is BacnetNetworkNumberIs) break;
    }
  }

  /// `127.0.0.1` and the port of [config].
  @override
  Future<BacnetAddressRecipient> localAddress() async {
    _checkStarted();
    final port = _config.port;
    return BacnetAddressRecipient(
      network: 0,
      mac: [127, 0, 0, 1, port >> 8, port & 0xFF],
    );
  }

  @override
  Future<BacnetStats> stats() async => BacnetStats(
    queuedRequests: 0,
    inFlightRequests: 0,
    completedRequests: _completed,
    failedRequests: _failed,
    timeouts: _timeouts,
    packetsReceived: _completed,
    requestsSent: _completed + _failed,
    repliesDropped: 0,
    eventsDropped: 0,
    boundDevices: _bound.length,
    bindingDevices: 0,
    freeTransactions: 255,
    pollCalls: 0,
  );

  void _checkStarted() {
    if (!_started) throw const BacnetNotInitializedException();
  }

  /// Runs [answer] against the device after the simulated latency.
  Future<T> _request<T>(
    BacnetConfirmedService? service,
    int deviceId,
    BacnetCancelToken? cancelToken,
    T Function(FakeBacnetDevice device) answer,
  ) {
    Future<T> run() async {
      _checkStarted();
      final device = _devices[deviceId];
      await Future<void>.delayed(latency + (device?.latency ?? Duration.zero));
      try {
        if (device == null) {
          throw BacnetDeviceNotFoundException(
            'device $deviceId did not answer Who-Is',
            deviceId: deviceId,
          );
        }
        if (!device.online ||
            (device.communication == BacnetCommunicationState.disable &&
                service != BacnetConfirmedService.deviceCommunicationControl &&
                service != BacnetConfirmedService.reinitializeDevice)) {
          _timeouts++;
          throw BacnetTimeoutException('device $deviceId did not answer');
        }
        _bound.add(deviceId);
        if (device.unsupportedServices.contains(service)) {
          throw BacnetRejectException(
            'device $deviceId rejected the request',
            reason: BacnetRejectReason.unrecognizedService,
          );
        }
        final result = answer(device);
        _completed++;
        return result;
      } on BacnetException {
        _failed++;
        rethrow;
      }
    }

    return cancelToken == null ? run() : cancelToken.guard(run());
  }
}
