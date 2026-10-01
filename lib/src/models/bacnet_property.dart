/// @docImport '../client/bacnet_client.dart';
/// @docImport '../server/bacnet_server.dart';
library;

import 'package:meta/meta.dart';

import '../constants/engineering_units.dart';
import '../constants/enumerations.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import 'alarms.dart';
import 'bacnet_value.dart';
import 'complex_values.dart';

/// A property whose BACnet datatype is known, so it is read as a Dart type
/// [T] instead of a generic [BacnetValue].
///
/// [BacnetProperties] defines the standard properties:
///
/// ```dart
/// final String name = await client.read(1234, sensor, BacnetProperties.objectName);
/// final BacnetStatusFlags flags =
///     await client.read(1234, sensor, BacnetProperties.statusFlags);
/// ```
///
/// Properties the standard defines as read-only are plain
/// [BacnetProperty]s; the others are [BacnetWritableProperty]s, so writing
/// Status_Flags does not compile. Proprietary properties are defined the
/// same way:
///
/// ```dart
/// final setpointOffset = BacnetWritableProperty.real(BacnetPropertyId(512));
/// await client.write(1234, controller, setpointOffset, 1.5);
/// ```
@immutable
class BacnetProperty<T> {
  /// Creates a property that decodes its values with [decode].
  const BacnetProperty(this.id, this.decode);

  /// A read-only REAL property.
  static BacnetProperty<double> real(BacnetPropertyId id) =>
      BacnetProperty(id, _real);

  /// A read-only Double property.
  static BacnetProperty<double> doubleValue(BacnetPropertyId id) =>
      BacnetProperty(id, _double);

  /// A read-only Unsigned property.
  static BacnetProperty<int> unsigned(BacnetPropertyId id) =>
      BacnetProperty(id, _unsigned);

  /// A read-only Signed property.
  static BacnetProperty<int> signed(BacnetPropertyId id) =>
      BacnetProperty(id, _signed);

  /// A read-only BOOLEAN property.
  static BacnetProperty<bool> boolean(BacnetPropertyId id) =>
      BacnetProperty(id, _boolean);

  /// A read-only CharacterString property.
  static BacnetProperty<String> characterString(BacnetPropertyId id) =>
      BacnetProperty(id, _string);

  /// A read-only Enumerated property, read as its number.
  static BacnetProperty<int> enumerated(BacnetPropertyId id) =>
      BacnetProperty(id, _enumerated);

  /// A read-only property of any datatype.
  static BacnetProperty<BacnetValue> any(BacnetPropertyId id) =>
      BacnetProperty(id, _any);

  /// The property identifier.
  final BacnetPropertyId id;

  /// Converts a read value to [T]. Throws a [BacnetDecodeException] if the
  /// device returned another datatype.
  final T Function(BacnetValue value) decode;

  @override
  String toString() => 'BacnetProperty<$T>(${id.label})';
}

/// A property that can also be written: [encode] converts a [T] to the
/// value sent to the device.
class BacnetWritableProperty<T> extends BacnetProperty<T> {
  /// Creates a writable property.
  const BacnetWritableProperty(super.id, super.decode, this.encode);

  /// A REAL property.
  static BacnetWritableProperty<double> real(BacnetPropertyId id) =>
      BacnetWritableProperty(id, _real, _encodeReal);

  /// A Double property.
  static BacnetWritableProperty<double> doubleValue(BacnetPropertyId id) =>
      BacnetWritableProperty(id, _double, _encodeDouble);

  /// An Unsigned property.
  static BacnetWritableProperty<int> unsigned(BacnetPropertyId id) =>
      BacnetWritableProperty(id, _unsigned, _encodeUnsigned);

  /// A Signed property.
  static BacnetWritableProperty<int> signed(BacnetPropertyId id) =>
      BacnetWritableProperty(id, _signed, _encodeSigned);

  /// A BOOLEAN property.
  static BacnetWritableProperty<bool> boolean(BacnetPropertyId id) =>
      BacnetWritableProperty(id, _boolean, _encodeBoolean);

  /// A CharacterString property.
  static BacnetWritableProperty<String> characterString(BacnetPropertyId id) =>
      BacnetWritableProperty(id, _string, _encodeString);

  /// An Enumerated property, read and written as its number.
  static BacnetWritableProperty<int> enumerated(BacnetPropertyId id) =>
      BacnetWritableProperty(id, _enumerated, _encodeEnumerated);

  /// A property of any datatype, read and written as [BacnetValue].
  static BacnetWritableProperty<BacnetValue> any(BacnetPropertyId id) =>
      BacnetWritableProperty(id, _any, _any);

  /// Converts a value to what is written to the device.
  ///
  /// Prefer [encodeValue] where the property may be typed as a supertype
  /// (see there).
  final BacnetValue Function(T value) encode;

  /// Converts [value], which must be a [T], to what is written to the
  /// device; an [int] is accepted for a [double] property.
  ///
  /// Generic methods such as `write<T>(property, value)` infer `T` from
  /// both arguments: `write(BacnetProperties.analogPresentValue, 35)`
  /// infers `num`. [encode] then cannot be called through the
  /// `BacnetWritableProperty<num>` view, this method can. Throws an
  /// [ArgumentError] for a value of another type.
  BacnetValue encodeValue(Object? value) {
    if (value is T) return encode(value);
    if (value is int && 0.0 is T) return encode(value.toDouble() as T);
    throw ArgumentError.value(value, 'value', 'not a $T value of ${id.label}');
  }
}

/// The standard properties with their datatypes (ASHRAE 135 clause 12).
///
/// Present_Value has a different datatype per object type, so there is one
/// per kind of object (`analogPresentValue`, `binaryPresentValue`, ...).
abstract final class BacnetProperties {
  // ---- all objects -----------------------------------------------------------

  /// Object_Identifier.
  static const objectIdentifier = BacnetProperty<BacnetObject>(
    BacnetPropertyId.objectIdentifier,
    _objectId,
  );

  /// Object_Name.
  static const objectName = BacnetWritableProperty<String>(
    BacnetPropertyId.objectName,
    _string,
    _encodeString,
  );

  /// Object_Type.
  static const objectType = BacnetProperty<BacnetObjectType>(
    BacnetPropertyId.objectType,
    _objectType,
  );

  /// Description.
  static const description = BacnetWritableProperty<String>(
    BacnetPropertyId.description,
    _string,
    _encodeString,
  );

  /// Property_List: the properties of the object.
  static const propertyList = BacnetProperty<List<BacnetPropertyId>>(
    BacnetPropertyId.propertyList,
    _propertyList,
  );

  /// Status_Flags.
  static const statusFlags = BacnetProperty<BacnetStatusFlags>(
    BacnetPropertyId.statusFlags,
    _statusFlags,
  );

  /// Event_State.
  static const eventState = BacnetProperty<BacnetEventState>(
    BacnetPropertyId.eventState,
    _eventState,
  );

  /// Reliability (writable while the object is out of service).
  static const reliability = BacnetWritableProperty<BacnetReliability>(
    BacnetPropertyId.reliability,
    _reliability,
    _encodeEnumerated,
  );

  /// Out_Of_Service.
  static const outOfService = BacnetWritableProperty<bool>(
    BacnetPropertyId.outOfService,
    _boolean,
    _encodeBoolean,
  );

  /// Units.
  static const units = BacnetWritableProperty<BacnetEngineeringUnits>(
    BacnetPropertyId.units,
    _units,
    _encodeEnumerated,
  );

  // ---- present values --------------------------------------------------------

  /// Present_Value of Analog Input/Output/Value, Loop, Lighting Output and
  /// Pulse Converter objects (REAL).
  static const analogPresentValue = BacnetWritableProperty<double>(
    BacnetPropertyId.presentValue,
    _real,
    _encodeReal,
  );

  /// Present_Value of Binary Input/Output/Value objects.
  static const binaryPresentValue = BacnetWritableProperty<BacnetBinaryPV>(
    BacnetPropertyId.presentValue,
    _binaryPV,
    _encodeEnumerated,
  );

  /// Present_Value of Multi-state Input/Output/Value objects (the state,
  /// 1-based).
  static const multiStatePresentValue = BacnetWritableProperty<int>(
    BacnetPropertyId.presentValue,
    _unsigned,
    _encodeUnsigned,
  );

  /// Present_Value of Integer Value objects (Signed).
  static const integerPresentValue = BacnetWritableProperty<int>(
    BacnetPropertyId.presentValue,
    _signed,
    _encodeSigned,
  );

  /// Present_Value of Positive Integer Value and Accumulator objects
  /// (Unsigned).
  static const positiveIntegerPresentValue = BacnetWritableProperty<int>(
    BacnetPropertyId.presentValue,
    _unsigned,
    _encodeUnsigned,
  );

  /// Present_Value of Large Analog Value objects (Double).
  static const largeAnalogPresentValue = BacnetWritableProperty<double>(
    BacnetPropertyId.presentValue,
    _double,
    _encodeDouble,
  );

  /// Present_Value of CharacterString Value objects.
  static const characterStringPresentValue = BacnetWritableProperty<String>(
    BacnetPropertyId.presentValue,
    _string,
    _encodeString,
  );

  /// Priority_Array of commandable objects.
  static const priorityArray = BacnetProperty<BacnetPriorityArray>(
    BacnetPropertyId.priorityArray,
    BacnetPriorityArray.fromValue,
  );

  // ---- analog objects --------------------------------------------------------

  /// COV_Increment.
  static const covIncrement = BacnetWritableProperty<double>(
    BacnetPropertyId.covIncrement,
    _real,
    _encodeReal,
  );

  /// Min_Pres_Value.
  static const minPresValue = BacnetWritableProperty<double>(
    BacnetPropertyId.minPresValue,
    _real,
    _encodeReal,
  );

  /// Max_Pres_Value.
  static const maxPresValue = BacnetWritableProperty<double>(
    BacnetPropertyId.maxPresValue,
    _real,
    _encodeReal,
  );

  /// Resolution.
  static const resolution = BacnetProperty<double>(
    BacnetPropertyId.resolution,
    _real,
  );

  /// High_Limit.
  static const highLimit = BacnetWritableProperty<double>(
    BacnetPropertyId.highLimit,
    _real,
    _encodeReal,
  );

  /// Low_Limit.
  static const lowLimit = BacnetWritableProperty<double>(
    BacnetPropertyId.lowLimit,
    _real,
    _encodeReal,
  );

  /// Deadband.
  static const deadband = BacnetWritableProperty<double>(
    BacnetPropertyId.deadband,
    _real,
    _encodeReal,
  );

  /// Limit_Enable.
  static const limitEnable = BacnetWritableProperty<BacnetLimitEnable>(
    BacnetPropertyId.limitEnable,
    BacnetLimitEnable.fromValue,
    _encodeLimitEnable,
  );

  // ---- binary and multi-state objects ----------------------------------------

  /// Polarity of binary objects.
  static const polarity = BacnetWritableProperty<BacnetPolarity>(
    BacnetPropertyId.polarity,
    _polarity,
    _encodeEnumerated,
  );

  /// Number_Of_States of multi-state objects.
  static const numberOfStates = BacnetWritableProperty<int>(
    BacnetPropertyId.numberOfStates,
    _unsigned,
    _encodeUnsigned,
  );

  /// State_Text of multi-state objects (state 1 first).
  static const stateText = BacnetWritableProperty<List<String>>(
    BacnetPropertyId.stateText,
    _stringList,
    _encodeStringList,
  );

  // ---- event reporting ---------------------------------------------------------

  /// Event_Enable.
  static const eventEnable = BacnetWritableProperty<BacnetEventTransitionBits>(
    BacnetPropertyId.eventEnable,
    BacnetEventTransitionBits.fromValue,
    _encodeTransitionBits,
  );

  /// Acked_Transitions.
  static const ackedTransitions = BacnetProperty<BacnetEventTransitionBits>(
    BacnetPropertyId.ackedTransitions,
    BacnetEventTransitionBits.fromValue,
  );

  /// Event_Time_Stamps: the last TO-OFFNORMAL, TO-FAULT and TO-NORMAL
  /// transitions.
  static const eventTimeStamps = BacnetProperty<List<BacnetTimeStamp>>(
    BacnetPropertyId.eventTimeStamps,
    BacnetTimeStamp.listFromValue,
  );

  /// Notification_Class.
  static const notificationClass = BacnetWritableProperty<int>(
    BacnetPropertyId.notificationClass,
    _unsigned,
    _encodeUnsigned,
  );

  /// Time_Delay in seconds.
  static const timeDelay = BacnetWritableProperty<int>(
    BacnetPropertyId.timeDelay,
    _unsigned,
    _encodeUnsigned,
  );

  /// Alarm_Value of binary inputs and values: the state that is off-normal.
  static const binaryAlarmValue = BacnetWritableProperty<BacnetBinaryPV>(
    BacnetPropertyId.alarmValue,
    _binaryPV,
    _encodeEnumerated,
  );

  /// Notify_Type: whether the transitions of the object are alarms or
  /// events.
  static const notifyType = BacnetWritableProperty<BacnetNotifyType>(
    BacnetPropertyId.notifyType,
    _notifyType,
    _encodeEnumerated,
  );

  /// Event_Detection_Enable: false disables event reporting of the object.
  static const eventDetectionEnable = BacnetWritableProperty<bool>(
    BacnetPropertyId.eventDetectionEnable,
    _boolean,
    _encodeBoolean,
  );

  /// Event_Message_Texts: the texts of the last TO-OFFNORMAL, TO-FAULT and
  /// TO-NORMAL notifications.
  static const eventMessageTexts = BacnetProperty<List<String>>(
    BacnetPropertyId.eventMessageTexts,
    _stringList,
  );

  // ---- notification class ------------------------------------------------------

  /// Priority of a Notification Class: the priorities of its transitions.
  static const priority = BacnetWritableProperty<BacnetEventPriorities>(
    BacnetPropertyId.priority,
    BacnetEventPriorities.fromValue,
    _encodePriorities,
  );

  /// Ack_Required of a Notification Class: the transitions that need an
  /// acknowledgement.
  static const ackRequired = BacnetWritableProperty<BacnetEventTransitionBits>(
    BacnetPropertyId.ackRequired,
    BacnetEventTransitionBits.fromValue,
    _encodeTransitionBits,
  );

  /// Recipient_List of a Notification Class: where its notifications go.
  ///
  /// Add or remove single recipients with [BacnetClient.addListElements]
  /// and [BacnetClient.removeListElements] instead of writing the whole
  /// list, which would drop recipients other clients added meanwhile.
  static const recipientList = BacnetWritableProperty<List<BacnetDestination>>(
    BacnetPropertyId.recipientList,
    BacnetDestination.listFromValue,
    BacnetDestination.listToValue,
  );

  // ---- device ----------------------------------------------------------------

  /// Object_List of the Device object.
  static const objectList = BacnetProperty<List<BacnetObject>>(
    BacnetPropertyId.objectList,
    _objectList,
  );

  /// System_Status.
  static const systemStatus = BacnetProperty<BacnetDeviceStatus>(
    BacnetPropertyId.systemStatus,
    _deviceStatus,
  );

  /// Vendor_Name.
  static const vendorName = BacnetProperty<String>(
    BacnetPropertyId.vendorName,
    _string,
  );

  /// Vendor_Identifier.
  static const vendorIdentifier = BacnetProperty<int>(
    BacnetPropertyId.vendorIdentifier,
    _unsigned,
  );

  /// Model_Name.
  static const modelName = BacnetProperty<String>(
    BacnetPropertyId.modelName,
    _string,
  );

  /// Firmware_Revision.
  static const firmwareRevision = BacnetProperty<String>(
    BacnetPropertyId.firmwareRevision,
    _string,
  );

  /// Application_Software_Version.
  static const applicationSoftwareVersion = BacnetProperty<String>(
    BacnetPropertyId.applicationSoftwareVersion,
    _string,
  );

  /// Location.
  static const location = BacnetWritableProperty<String>(
    BacnetPropertyId.location,
    _string,
    _encodeString,
  );

  /// Protocol_Version.
  static const protocolVersion = BacnetProperty<int>(
    BacnetPropertyId.protocolVersion,
    _unsigned,
  );

  /// Protocol_Revision.
  static const protocolRevision = BacnetProperty<int>(
    BacnetPropertyId.protocolRevision,
    _unsigned,
  );

  /// Max_APDU_Length_Accepted.
  static const maxApduLengthAccepted = BacnetProperty<int>(
    BacnetPropertyId.maxApduLengthAccepted,
    _unsigned,
  );

  /// Segmentation_Supported.
  static const segmentationSupported = BacnetProperty<BacnetSegmentation>(
    BacnetPropertyId.segmentationSupported,
    _segmentation,
  );

  /// APDU_Timeout in milliseconds.
  static const apduTimeout = BacnetWritableProperty<int>(
    BacnetPropertyId.apduTimeout,
    _unsigned,
    _encodeUnsigned,
  );

  /// Number_Of_APDU_Retries.
  static const numberOfApduRetries = BacnetWritableProperty<int>(
    BacnetPropertyId.numberOfApduRetries,
    _unsigned,
    _encodeUnsigned,
  );

  /// Database_Revision.
  static const databaseRevision = BacnetProperty<int>(
    BacnetPropertyId.databaseRevision,
    _unsigned,
  );

  /// Local_Date.
  static const localDate = BacnetProperty<BacnetDate>(
    BacnetPropertyId.localDate,
    _date,
  );

  /// Local_Time.
  static const localTime = BacnetProperty<BacnetTime>(
    BacnetPropertyId.localTime,
    _time,
  );

  /// Configuration_Files of the Device object: the File objects a backup
  /// reads and a restore writes.
  static const configurationFiles = BacnetProperty<List<BacnetObject>>(
    BacnetPropertyId.configurationFiles,
    _objectList,
  );

  /// Backup_And_Restore_State of the Device object.
  static const backupAndRestoreState = BacnetProperty<BacnetBackupState>(
    BacnetPropertyId.backupAndRestoreState,
    _backupState,
  );

  /// Backup_Preparation_Time in seconds: how long the device may not answer
  /// after accepting a backup.
  static const backupPreparationTime = BacnetProperty<int>(
    BacnetPropertyId.backupPreparationTime,
    _unsigned,
  );

  /// Restore_Preparation_Time in seconds.
  static const restorePreparationTime = BacnetProperty<int>(
    BacnetPropertyId.restorePreparationTime,
    _unsigned,
  );

  /// Restore_Completion_Time in seconds: how long the device may not answer
  /// after the end of a restore.
  static const restoreCompletionTime = BacnetProperty<int>(
    BacnetPropertyId.restoreCompletionTime,
    _unsigned,
  );

  /// Backup_Failure_Timeout in seconds.
  static const backupFailureTimeout = BacnetWritableProperty<int>(
    BacnetPropertyId.backupFailureTimeout,
    _unsigned,
    _encodeUnsigned,
  );

  /// Last_Restore_Time of the Device object.
  static const lastRestoreTime = BacnetProperty<BacnetTimeStamp>(
    BacnetPropertyId.lastRestoreTime,
    BacnetTimeStamp.fromValue,
  );

  /// Device_Address_Binding.
  static const deviceAddressBinding =
      BacnetProperty<List<BacnetAddressBinding>>(
        BacnetPropertyId.deviceAddressBinding,
        BacnetAddressBinding.listFromValue,
      );

  // ---- schedule and calendar ---------------------------------------------------

  /// Weekly_Schedule of a Schedule object.
  static const weeklySchedule = BacnetWritableProperty<BacnetWeeklySchedule>(
    BacnetPropertyId.weeklySchedule,
    BacnetWeeklySchedule.fromValue,
    _encodeWeeklySchedule,
  );

  /// Exception_Schedule of a Schedule object.
  static const exceptionSchedule =
      BacnetWritableProperty<List<BacnetSpecialEvent>>(
        BacnetPropertyId.exceptionSchedule,
        BacnetSpecialEvent.listFromValue,
        BacnetSpecialEvent.listToValue,
      );

  /// Effective_Period of a Schedule object.
  static const effectivePeriod = BacnetWritableProperty<BacnetDateRange>(
    BacnetPropertyId.effectivePeriod,
    BacnetDateRange.fromValue,
    _encodeDateRange,
  );

  /// Schedule_Default of a Schedule object.
  static const scheduleDefault = BacnetWritableProperty<BacnetValue>(
    BacnetPropertyId.scheduleDefault,
    _any,
    _any,
  );

  /// List_Of_Object_Property_References of a Schedule object.
  static const listOfObjectPropertyReferences =
      BacnetWritableProperty<List<BacnetDeviceObjectPropertyReference>>(
        BacnetPropertyId.listOfObjectPropertyReferences,
        BacnetDeviceObjectPropertyReference.listFromValue,
        BacnetDeviceObjectPropertyReference.listToValue,
      );

  /// Present_Value of a Schedule object: the value it writes now.
  static const schedulePresentValue = BacnetWritableProperty<BacnetValue>(
    BacnetPropertyId.presentValue,
    _any,
    _any,
  );

  /// Priority_For_Writing of a Schedule object (1..16).
  static const priorityForWriting = BacnetProperty<int>(
    BacnetPropertyId.priorityForWriting,
    _unsigned,
  );

  /// Present_Value of a Calendar object: true when today is in Date_List.
  static const calendarPresentValue = BacnetProperty<bool>(
    BacnetPropertyId.presentValue,
    _boolean,
  );

  /// Date_List of a Calendar object.
  static const dateList = BacnetWritableProperty<List<BacnetCalendarEntry>>(
    BacnetPropertyId.dateList,
    BacnetCalendarEntry.listFromValue,
    _encodeCalendarEntries,
  );

  // ---- trend log ---------------------------------------------------------------

  /// Enable (formerly Log_Enable) of a Trend Log object.
  static const enable = BacnetWritableProperty<bool>(
    BacnetPropertyId.enable,
    _boolean,
    _encodeBoolean,
  );

  /// Start_Time of a Trend Log object.
  static const startTime = BacnetWritableProperty<BacnetDateTime>(
    BacnetPropertyId.startTime,
    BacnetDateTime.fromValue,
    _encodeDateTime,
  );

  /// Stop_Time of a Trend Log object.
  static const stopTime = BacnetWritableProperty<BacnetDateTime>(
    BacnetPropertyId.stopTime,
    BacnetDateTime.fromValue,
    _encodeDateTime,
  );

  /// Log_DeviceObjectProperty of a Trend Log object.
  static const logDeviceObjectProperty =
      BacnetWritableProperty<BacnetDeviceObjectPropertyReference>(
        BacnetPropertyId.logDeviceObjectProperty,
        BacnetDeviceObjectPropertyReference.fromValue,
        _encodeReference,
      );

  /// Log_Interval in hundredths of a second.
  static const logInterval = BacnetWritableProperty<int>(
    BacnetPropertyId.logInterval,
    _unsigned,
    _encodeUnsigned,
  );

  /// Stop_When_Full.
  static const stopWhenFull = BacnetWritableProperty<bool>(
    BacnetPropertyId.stopWhenFull,
    _boolean,
    _encodeBoolean,
  );

  /// Buffer_Size in records.
  static const bufferSize = BacnetWritableProperty<int>(
    BacnetPropertyId.bufferSize,
    _unsigned,
    _encodeUnsigned,
  );

  /// Record_Count (writing 0 clears the log buffer).
  static const recordCount = BacnetWritableProperty<int>(
    BacnetPropertyId.recordCount,
    _unsigned,
    _encodeUnsigned,
  );

  /// Total_Record_Count.
  static const totalRecordCount = BacnetProperty<int>(
    BacnetPropertyId.totalRecordCount,
    _unsigned,
  );

  // ---- file ----------------------------------------------------------------------

  /// File_Type of a File object: a media type such as `text/plain`.
  static const fileType = BacnetWritableProperty<String>(
    BacnetPropertyId.fileType,
    _string,
    _encodeString,
  );

  /// File_Size of a File object in octets; writing it truncates or extends
  /// a stream file where the device allows it.
  static const fileSize = BacnetWritableProperty<int>(
    BacnetPropertyId.fileSize,
    _unsigned,
    _encodeUnsigned,
  );

  /// Modification_Date of a File object: the time of the last change.
  static const modificationDate = BacnetProperty<BacnetDateTime>(
    BacnetPropertyId.modificationDate,
    BacnetDateTime.fromValue,
  );

  /// Archive of a File object: set by a backup, cleared by changes.
  static const archive = BacnetWritableProperty<bool>(
    BacnetPropertyId.archive,
    _boolean,
    _encodeBoolean,
  );

  /// Read_Only of a File object.
  static const readOnly = BacnetProperty<bool>(
    BacnetPropertyId.readOnly,
    _boolean,
  );

  /// File_Access_Method of a File object: stream or record access.
  static const fileAccessMethod = BacnetProperty<BacnetFileAccessMethod>(
    BacnetPropertyId.fileAccessMethod,
    _fileAccessMethod,
  );
}

/// Typed access to the results of [BacnetClient.readMultiple].
extension BacnetTypedPropertyResults
    on Map<BacnetPropertyId, BacnetPropertyResult> {
  /// The value of [property] as [T], or null when the device returned an
  /// error, left the property out or sent another datatype.
  T? get<T>(BacnetProperty<T> property) {
    final value = valueOf(property.id);
    if (value == null) return null;
    try {
      return property.decode(value);
    } on BacnetDecodeException {
      return null;
    }
  }
}

// ---- decoders ------------------------------------------------------------------

Never _wrongType(String expected, BacnetValue value) =>
    throw BacnetDecodeException('expected $expected, got $value');

BacnetValue _any(BacnetValue value) => value;

BacnetBackupState _backupState(BacnetValue value) => switch (value) {
  BacnetEnumerated(:final value) => BacnetBackupState(value),
  _ => _wrongType('Enumerated', value),
};

BacnetFileAccessMethod _fileAccessMethod(BacnetValue value) => switch (value) {
  BacnetEnumerated(:final value) => BacnetFileAccessMethod(value),
  _ => _wrongType('Enumerated', value),
};

double _real(BacnetValue value) => switch (value) {
  BacnetReal(:final value) => value,
  _ => _wrongType('Real', value),
};

double _double(BacnetValue value) => switch (value) {
  BacnetDouble(:final value) => value,
  _ => _wrongType('Double', value),
};

int _unsigned(BacnetValue value) => switch (value) {
  BacnetUnsigned(:final value) => value,
  _ => _wrongType('Unsigned', value),
};

int _signed(BacnetValue value) => switch (value) {
  BacnetSigned(:final value) => value,
  _ => _wrongType('Signed', value),
};

bool _boolean(BacnetValue value) => switch (value) {
  BacnetBoolean(:final value) => value,
  _ => _wrongType('Boolean', value),
};

String _string(BacnetValue value) => switch (value) {
  BacnetCharacterString(:final value) => value,
  _ => _wrongType('CharacterString', value),
};

int _enumerated(BacnetValue value) => switch (value) {
  BacnetEnumerated(:final value) => value,
  _ => _wrongType('Enumerated', value),
};

BacnetDate _date(BacnetValue value) => switch (value) {
  final BacnetDate date => date,
  _ => _wrongType('Date', value),
};

BacnetTime _time(BacnetValue value) => switch (value) {
  final BacnetTime time => time,
  _ => _wrongType('Time', value),
};

BacnetObject _objectId(BacnetValue value) => switch (value) {
  final BacnetObject object => object,
  _ => _wrongType('ObjectIdentifier', value),
};

BacnetStatusFlags _statusFlags(BacnetValue value) =>
    value.asStatusFlags ?? _wrongType('BitString', value);

BacnetObjectType _objectType(BacnetValue value) =>
    BacnetObjectType(_enumerated(value));

BacnetEventState _eventState(BacnetValue value) =>
    BacnetEventState(_enumerated(value));

BacnetNotifyType _notifyType(BacnetValue value) =>
    BacnetNotifyType(_enumerated(value));

BacnetReliability _reliability(BacnetValue value) =>
    BacnetReliability(_enumerated(value));

BacnetEngineeringUnits _units(BacnetValue value) =>
    BacnetEngineeringUnits(_enumerated(value));

BacnetBinaryPV _binaryPV(BacnetValue value) =>
    BacnetBinaryPV(_enumerated(value));

BacnetPolarity _polarity(BacnetValue value) =>
    BacnetPolarity(_enumerated(value));

BacnetDeviceStatus _deviceStatus(BacnetValue value) =>
    BacnetDeviceStatus(_enumerated(value));

BacnetSegmentation _segmentation(BacnetValue value) =>
    BacnetSegmentation(_enumerated(value));

List<BacnetObject> _objectList(BacnetValue value) =>
    List.unmodifiable(value.asList.map(_objectId));

List<String> _stringList(BacnetValue value) =>
    List.unmodifiable(value.asList.map(_string));

List<BacnetPropertyId> _propertyList(BacnetValue value) => List.unmodifiable(
  value.asList.map((item) => BacnetPropertyId(_enumerated(item))),
);

// ---- encoders ------------------------------------------------------------------

BacnetValue _encodeReal(double value) => BacnetReal(value);

BacnetValue _encodeDouble(double value) => BacnetDouble(value);

BacnetValue _encodeUnsigned(int value) => BacnetUnsigned(value);

BacnetValue _encodeSigned(int value) => BacnetSigned(value);

BacnetValue _encodeBoolean(bool value) => BacnetBoolean(value);

BacnetValue _encodeString(String value) => BacnetCharacterString(value);

BacnetValue _encodeEnumerated(int value) => BacnetEnumerated(value);

BacnetValue _encodeStringList(List<String> value) =>
    BacnetList([for (final text in value) BacnetCharacterString(text)]);

BacnetValue _encodeLimitEnable(BacnetLimitEnable value) => value.toValue();

BacnetValue _encodeTransitionBits(BacnetEventTransitionBits value) =>
    value.toValue();

BacnetValue _encodeWeeklySchedule(BacnetWeeklySchedule value) =>
    value.toValue();

BacnetValue _encodeDateRange(BacnetDateRange value) => value.toValue();

BacnetValue _encodeCalendarEntries(List<BacnetCalendarEntry> value) =>
    BacnetList([for (final entry in value) entry.toValue()]);

BacnetValue _encodeDateTime(BacnetDateTime value) => value.toValue();

BacnetValue _encodeReference(BacnetDeviceObjectPropertyReference value) =>
    value.toValue();

BacnetValue _encodePriorities(BacnetEventPriorities value) => value.toValue();
