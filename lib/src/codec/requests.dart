import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../constants/enumerations.dart';
import '../constants/object_types.dart';
import '../models/bacnet_value.dart';
import '../models/channels.dart';
import '../models/complex_values.dart';
import '../models/events.dart';
import '../models/rpm_models.dart';
import '../models/wpm_models.dart';
import 'value_encoding.dart';
import 'writer.dart';

/// Encodes a ReadProperty request.
Uint8List encodeReadProperty(
  int objectType,
  int instance,
  int propertyId, {
  int arrayIndex = -1,
}) {
  final w = BacnetWriter(16)
    ..ctxObjectId(0, objectType, instance)
    ..ctxUnsigned(1, propertyId);
  if (arrayIndex >= 0) w.ctxUnsigned(2, arrayIndex);
  return w.toBytes();
}

/// Encodes a ReadPropertyMultiple request.
Uint8List encodeReadPropertyMultiple(
  List<BacnetReadAccessSpecification> specs,
) {
  final w = BacnetWriter(32 + specs.length * 16);
  for (final spec in specs) {
    w
      ..ctxObjectId(
        0,
        spec.objectIdentifier.type,
        spec.objectIdentifier.instance,
      )
      ..opening(1);
    for (final property in spec.properties) {
      w.ctxUnsigned(0, property.propertyIdentifier);
      if (property.propertyArrayIndex >= 0) {
        w.ctxUnsigned(1, property.propertyArrayIndex);
      }
    }
    w.closing(1);
  }
  return w.toBytes();
}

/// Encodes a WriteProperty request.
Uint8List encodeWriteProperty(
  int objectType,
  int instance,
  int propertyId,
  BacnetValue value, {
  int arrayIndex = -1,
  int priority = 16,
}) {
  final w = BacnetWriter(32)
    ..ctxObjectId(0, objectType, instance)
    ..ctxUnsigned(1, propertyId);
  if (arrayIndex >= 0) w.ctxUnsigned(2, arrayIndex);
  w.opening(3);
  encodeApplicationValue(w, value);
  w.closing(3);
  if (priority >= 1 && priority < 16) w.ctxUnsigned(4, priority);
  return w.toBytes();
}

/// Encodes a WritePropertyMultiple request.
Uint8List encodeWritePropertyMultiple(
  List<BacnetWriteAccessSpecification> specs,
) {
  final w = BacnetWriter();
  for (final spec in specs) {
    final object = spec.objectIdentifier;
    w
      ..ctxObjectId(0, object.type, object.instance)
      ..opening(1);
    for (final property in spec.listOfProperties) {
      w.ctxUnsigned(0, property.propertyIdentifier);
      if (property.propertyArrayIndex >= 0) {
        w.ctxUnsigned(1, property.propertyArrayIndex);
      }
      w.opening(2);
      encodeApplicationValue(w, property.value);
      w.closing(2);
      if (property.priority >= 1 && property.priority < 16) {
        w.ctxUnsigned(3, property.priority);
      }
    }
    w.closing(1);
  }
  return w.toBytes();
}

/// Encodes a SubscribeCOV request. A [lifetime] of null with
/// [cancel] = true encodes a cancellation.
Uint8List encodeSubscribeCov({
  required int subscriberProcessId,
  required int objectType,
  required int instance,
  bool confirmed = false,
  int? lifetime,
  bool cancel = false,
}) {
  final w = BacnetWriter(24)
    ..ctxUnsigned(0, subscriberProcessId)
    ..ctxObjectId(1, objectType, instance);
  if (!cancel) {
    w.ctxBoolean(2, confirmed);
    w.ctxUnsigned(3, lifetime ?? 0);
  }
  return w.toBytes();
}

/// Encodes a SubscribeCOVProperty request.
Uint8List encodeSubscribeCovProperty({
  required int subscriberProcessId,
  required int objectType,
  required int instance,
  required int propertyId,
  int arrayIndex = -1,
  bool confirmed = false,
  int? lifetime,
  double? covIncrement,
  bool cancel = false,
}) {
  final w = BacnetWriter(32)
    ..ctxUnsigned(0, subscriberProcessId)
    ..ctxObjectId(1, objectType, instance);
  if (!cancel) {
    w.ctxBoolean(2, confirmed);
    w.ctxUnsigned(3, lifetime ?? 0);
  }
  w
    ..opening(4)
    ..ctxUnsigned(0, propertyId);
  if (arrayIndex >= 0) w.ctxUnsigned(1, arrayIndex);
  w.closing(4);
  if (covIncrement != null && !cancel) w.ctxReal(5, covIncrement);
  return w.toBytes();
}

/// The items of a list property to read with ReadRange (the Range choice
/// of ASHRAE 135 clause 15.8.1.1.4).
///
/// A negative `count` reads backwards from the reference item.
///
/// ```dart
/// // the newest 50 records of a log buffer with 1000 records
/// await client.readRange(1234, BacnetObjectType.trendLog, 1,
///     BacnetPropertyId.logBuffer,
///     range: const BacnetRange.byPosition(1000, -50));
/// ```
@immutable
sealed class BacnetRange {
  const BacnetRange();

  /// The whole list.
  const factory BacnetRange.all() = BacnetRangeAll;

  /// [count] items from position [index] (1 based).
  const factory BacnetRange.byPosition(int index, int count) =
      BacnetRangeByPosition;

  /// [count] records from sequence number [sequenceNumber] (log buffers).
  const factory BacnetRange.bySequenceNumber(int sequenceNumber, int count) =
      BacnetRangeBySequenceNumber;

  /// [count] records from the first one logged at or after [time] (log
  /// buffers; before [time] when [count] is negative).
  const factory BacnetRange.byTime(DateTime time, int count) =
      BacnetRangeByTime;
}

/// The whole list.
final class BacnetRangeAll extends BacnetRange {
  /// Creates the range.
  const BacnetRangeAll();
}

/// Items by position.
final class BacnetRangeByPosition extends BacnetRange {
  /// Creates the range.
  const BacnetRangeByPosition(this.index, this.count)
    : assert(index >= 1, 'positions start at 1');

  /// Position of the reference item (1 based).
  final int index;

  /// Number of items; negative reads backwards.
  final int count;
}

/// Log records by sequence number.
final class BacnetRangeBySequenceNumber extends BacnetRange {
  /// Creates the range.
  const BacnetRangeBySequenceNumber(this.sequenceNumber, this.count);

  /// Sequence number of the reference record.
  final int sequenceNumber;

  /// Number of records; negative reads backwards.
  final int count;
}

/// Log records by time.
final class BacnetRangeByTime extends BacnetRange {
  /// Creates the range.
  const BacnetRangeByTime(this.time, this.count);

  /// Reference time (device local time).
  final DateTime time;

  /// Number of records; negative reads backwards.
  final int count;
}

/// Encodes a ReadRange request.
Uint8List encodeReadRange(
  int objectType,
  int instance,
  int propertyId, {
  int arrayIndex = -1,
  BacnetRange range = const BacnetRangeAll(),
}) {
  final w = BacnetWriter(32)
    ..ctxObjectId(0, objectType, instance)
    ..ctxUnsigned(1, propertyId);
  if (arrayIndex >= 0) w.ctxUnsigned(2, arrayIndex);
  switch (range) {
    case BacnetRangeAll():
      break;
    case BacnetRangeByPosition(:final index, :final count):
      w
        ..opening(3)
        ..appUnsigned(index)
        ..appSigned(count)
        ..closing(3);
    case BacnetRangeBySequenceNumber(:final sequenceNumber, :final count):
      w
        ..opening(6)
        ..appUnsigned(sequenceNumber)
        ..appSigned(count)
        ..closing(6);
    case BacnetRangeByTime(:final time, :final count):
      w
        ..opening(7)
        ..appDate(BacnetDate.fromDateTime(time))
        ..appTime(BacnetTime.fromDateTime(time))
        ..appSigned(count)
        ..closing(7);
  }
  return w.toBytes();
}

/// Encodes a Who-Is request (both limits or none).
Uint8List encodeWhoIs({int? lowLimit, int? highLimit}) {
  if (lowLimit == null ||
      highLimit == null ||
      lowLimit < 0 ||
      highLimit < 0 ||
      lowLimit > BacnetObject.maxInstance ||
      highLimit > BacnetObject.maxInstance) {
    return Uint8List(0);
  }
  return (BacnetWriter(10)
        ..ctxUnsigned(0, lowLimit)
        ..ctxUnsigned(1, highLimit))
      .toBytes();
}

/// Encodes a Who-Has request for [object] or for the object named
/// [objectName] (exactly one), optionally limited to a device instance
/// range.
Uint8List encodeWhoHas({
  BacnetObject? object,
  String? objectName,
  int? lowLimit,
  int? highLimit,
}) {
  if ((object == null) == (objectName == null)) {
    throw ArgumentError('give either object or objectName');
  }
  final w = BacnetWriter(32);
  if (lowLimit != null && highLimit != null) {
    w
      ..ctxUnsigned(0, lowLimit)
      ..ctxUnsigned(1, highLimit);
  }
  if (object != null) {
    w.ctxObjectId(2, object.type, object.instance);
  } else {
    w.ctxCharacterString(3, objectName!);
  }
  return w.toBytes();
}

/// Encodes a (UTC)TimeSynchronization request.
Uint8List encodeTimeSynchronization(DateTime time) =>
    (BacnetWriter(10)
          ..appDate(BacnetDate.fromDateTime(time))
          ..appTime(BacnetTime.fromDateTime(time)))
        .toBytes();

/// Encodes a (Un)ConfirmedEventNotification request (ASHRAE 135 clause
/// 13.8).
Uint8List encodeEventNotification(EventNotificationEvent notification) {
  final n = notification;
  final w = BacnetWriter()
    ..ctxUnsigned(0, n.processId)
    ..ctxObjectId(1, BacnetObjectType.device, n.deviceId)
    ..ctxObjectId(2, n.object.type, n.object.instance);
  _timeStamp(w, 3, n.timeStamp);
  w
    ..ctxUnsigned(4, n.notificationClass)
    ..ctxUnsigned(5, n.priority)
    ..ctxUnsigned(6, n.eventType);
  if (n.messageText case final text?) w.ctxCharacterString(7, text);
  w.ctxUnsigned(8, n.notifyType);
  if (!n.isAckNotification) {
    w
      ..ctxBoolean(9, n.ackRequired)
      ..ctxUnsigned(10, n.fromState ?? BacnetEventState.normal);
  }
  w.ctxUnsigned(11, n.toState);
  if (n.eventValues case final values?) {
    w.opening(12);
    encodeApplicationValue(w, values.toValue());
    w.closing(12);
  }
  return w.toBytes();
}

/// Encodes an AcknowledgeAlarm request (ASHRAE 135 clause 13.5).
Uint8List encodeAcknowledgeAlarm({
  required int processId,
  required BacnetObject object,
  required BacnetEventState eventState,
  required BacnetTimeStamp timeStamp,
  required String source,
  required BacnetTimeStamp timeOfAcknowledgment,
}) {
  final w = BacnetWriter()
    ..ctxUnsigned(0, processId)
    ..ctxObjectId(1, object.type, object.instance)
    ..ctxUnsigned(2, eventState);
  _timeStamp(w, 3, timeStamp);
  w.ctxCharacterString(4, source);
  _timeStamp(w, 5, timeOfAcknowledgment);
  return w.toBytes();
}

void _timeStamp(BacnetWriter w, int tag, BacnetTimeStamp timeStamp) {
  w.opening(tag);
  encodeApplicationValue(w, timeStamp.toValue());
  w.closing(tag);
}

/// Encodes a GetEventInformation request (ASHRAE 135 clause 13.12) that
/// continues after [lastReceived].
Uint8List encodeGetEventInformation({BacnetObject? lastReceived}) {
  final w = BacnetWriter(8);
  if (lastReceived case final object?) {
    w.ctxObjectId(0, object.type, object.instance);
  }
  return w.toBytes();
}

/// Encodes an AddListElement or RemoveListElement request (ASHRAE 135
/// clauses 15.1 and 15.2); [elements] are the list elements one after
/// another.
Uint8List encodeListElements(
  int objectType,
  int instance,
  int propertyId,
  BacnetValue elements, {
  int arrayIndex = -1,
}) {
  final w = BacnetWriter()
    ..ctxObjectId(0, objectType, instance)
    ..ctxUnsigned(1, propertyId);
  if (arrayIndex >= 0) w.ctxUnsigned(2, arrayIndex);
  w.opening(3);
  encodeApplicationValue(w, elements);
  w.closing(3);
  return w.toBytes();
}

// ---- device management -------------------------------------------------------

/// Encodes a DeviceCommunicationControl request (ASHRAE 135 clause 16.1);
/// [duration] in whole minutes (1..65535), null for indefinitely.
Uint8List encodeDeviceCommunicationControl(
  BacnetCommunicationState state, {
  Duration? duration,
  String? password,
}) {
  final w = BacnetWriter(32);
  if (duration != null) {
    final minutes = duration.inMinutes;
    if (minutes < 1 || minutes > 0xFFFF) {
      throw ArgumentError.value(
        duration,
        'duration',
        'must be 1 to 65535 minutes',
      );
    }
    w.ctxUnsigned(0, minutes);
  }
  w.ctxUnsigned(1, state);
  if (password != null) w.ctxCharacterString(2, _password(password));
  return w.toBytes();
}

/// Encodes a ReinitializeDevice request (ASHRAE 135 clause 16.4).
Uint8List encodeReinitializeDevice(
  BacnetReinitializedState state, {
  String? password,
}) {
  final w = BacnetWriter(32)..ctxUnsigned(0, state);
  if (password != null) w.ctxCharacterString(1, _password(password));
  return w.toBytes();
}

String _password(String password) {
  if (password.isEmpty || password.runes.length > 20) {
    throw ArgumentError.value(
      password,
      'password',
      'must have 1 to 20 characters',
    );
  }
  return password;
}

/// Encodes a CreateObject request (ASHRAE 135 clause 15.3) for an object
/// of [type] whose instance the device chooses, or for [object].
Uint8List encodeCreateObject({
  BacnetObjectType? type,
  BacnetObject? object,
  List<BacnetPropertyValue> initialValues = const [],
}) {
  if ((type == null) == (object == null)) {
    throw ArgumentError('give either type or object');
  }
  final w = BacnetWriter()..opening(0);
  if (object != null) {
    w.ctxObjectId(1, object.type, object.instance);
  } else {
    w.ctxUnsigned(0, type!);
  }
  w.closing(0);
  if (initialValues.isNotEmpty) {
    w.opening(1);
    for (final value in initialValues) {
      w.ctxUnsigned(0, value.propertyIdentifier);
      if (value.propertyArrayIndex >= 0) {
        w.ctxUnsigned(1, value.propertyArrayIndex);
      }
      w.opening(2);
      encodeApplicationValue(w, value.value);
      w.closing(2);
      if (value.priority >= 1 && value.priority < 16) {
        w.ctxUnsigned(3, value.priority);
      }
    }
    w.closing(1);
  }
  return w.toBytes();
}

/// Encodes a DeleteObject request (ASHRAE 135 clause 15.4).
Uint8List encodeDeleteObject(BacnetObject object) =>
    (BacnetWriter(8)..appObjectId(object.type, object.instance)).toBytes();

/// Encodes an AtomicReadFile request with stream access ([records] false)
/// or record access (ASHRAE 135 clause 14.1).
Uint8List encodeAtomicReadFile(
  int fileInstance, {
  required int start,
  required int count,
  bool records = false,
}) {
  if (count < 0) throw ArgumentError.value(count, 'count', 'is negative');
  final tag = records ? 1 : 0;
  return (BacnetWriter(24)
        ..appObjectId(BacnetObjectType.file, fileInstance)
        ..opening(tag)
        ..appSigned(start)
        ..appUnsigned(count)
        ..closing(tag))
      .toBytes();
}

/// Encodes an AtomicWriteFile request with stream access (ASHRAE 135
/// clause 14.2); a [start] of -1 appends to the file.
Uint8List encodeAtomicWriteFileStream(
  int fileInstance,
  List<int> data, {
  int start = 0,
}) =>
    (BacnetWriter(data.length + 24)
          ..appObjectId(BacnetObjectType.file, fileInstance)
          ..opening(0)
          ..appSigned(start)
          ..appOctetString(data)
          ..closing(0))
        .toBytes();

/// Encodes an AtomicWriteFile request with record access; a [start] of -1
/// appends the records.
Uint8List encodeAtomicWriteFileRecords(
  int fileInstance,
  List<List<int>> records, {
  int start = 0,
}) {
  final w = BacnetWriter()
    ..appObjectId(BacnetObjectType.file, fileInstance)
    ..opening(1)
    ..appSigned(start)
    ..appUnsigned(records.length);
  for (final record in records) {
    w.appOctetString(record);
  }
  return (w..closing(1)).toBytes();
}

/// Encodes a (Confirmed or Unconfirmed)PrivateTransfer request (ASHRAE
/// 135 clause 16.2).
Uint8List encodePrivateTransfer(
  int vendorId,
  int serviceNumber, {
  BacnetValue? parameters,
}) {
  final w = BacnetWriter(32)
    ..ctxUnsigned(0, vendorId)
    ..ctxUnsigned(1, serviceNumber);
  if (parameters != null) {
    w.opening(2);
    encodeApplicationValue(w, parameters);
    w.closing(2);
  }
  return w.toBytes();
}

/// Encodes a Who-Am-I request: a device without a configured device
/// instance asks a supervisor for one (ASHRAE 135 clause 16.11).
Uint8List encodeWhoAmI({
  required int vendorId,
  required String modelName,
  required String serialNumber,
}) {
  RangeError.checkValueInInterval(vendorId, 0, 0xFFFF, 'vendorId');
  return (BacnetWriter(modelName.length + serialNumber.length + 16)
        ..appUnsigned(vendorId)
        ..appCharacterString(modelName)
        ..appCharacterString(serialNumber))
      .toBytes();
}

/// Encodes a You-Are request: assigns [deviceId] and [macAddress] to the
/// device with [vendorId], [modelName] and [serialNumber] (ASHRAE 135
/// clause 16.12).
Uint8List encodeYouAre({
  required int vendorId,
  required String modelName,
  required String serialNumber,
  int? deviceId,
  List<int>? macAddress,
}) {
  RangeError.checkValueInInterval(vendorId, 0, 0xFFFF, 'vendorId');
  if (deviceId == null && macAddress == null) {
    throw ArgumentError('give a deviceId, a macAddress or both');
  }
  final w = BacnetWriter(modelName.length + serialNumber.length + 32)
    ..appUnsigned(vendorId)
    ..appCharacterString(modelName)
    ..appCharacterString(serialNumber);
  if (deviceId != null) {
    RangeError.checkValueInInterval(deviceId, 0, 0x3FFFFE, 'deviceId');
    w.appObjectId(BacnetObjectType.device, deviceId);
  }
  if (macAddress != null) w.appOctetString(macAddress);
  return w.toBytes();
}

/// Encodes a WriteGroup request (ASHRAE 135 clause 15.11): [changes] for
/// the Channel objects whose Control_Groups contain [groupNumber].
Uint8List encodeWriteGroup(
  int groupNumber,
  List<BacnetGroupChannelValue> changes, {
  int writePriority = 16,
  bool? inhibitDelay,
}) {
  RangeError.checkValueInInterval(groupNumber, 1, 0xFFFFFFFF, 'groupNumber');
  RangeError.checkValueInInterval(writePriority, 1, 16, 'writePriority');
  final w = BacnetWriter(32 + changes.length * 16)
    ..ctxUnsigned(0, groupNumber)
    ..ctxUnsigned(1, writePriority)
    ..opening(2);
  for (final change in changes) {
    w.ctxUnsigned(0, change.channel);
    if (change.overridingPriority case final priority?) {
      w.ctxUnsigned(1, priority);
    }
    w.opening(2);
    encodeApplicationValue(w, change.value);
    w.closing(2);
  }
  w.closing(2);
  if (inhibitDelay != null) w.ctxBoolean(3, inhibitDelay);
  return w.toBytes();
}

/// Encodes a (Confirmed or Unconfirmed)TextMessage request from device
/// [sourceDevice] (ASHRAE 135 clause 16.5).
Uint8List encodeTextMessage(
  int sourceDevice,
  String message, {
  bool urgent = false,
  int? classNumber,
  String? classText,
}) {
  if (classNumber != null && classText != null) {
    throw ArgumentError('give at most one of classNumber and classText');
  }
  final w = BacnetWriter(message.length + 24)
    ..ctxObjectId(0, BacnetObjectType.device, sourceDevice);
  if (classNumber != null || classText != null) {
    w.opening(1);
    if (classNumber != null) {
      w.ctxUnsigned(0, classNumber);
    } else {
      w.ctxCharacterString(1, classText!);
    }
    w.closing(1);
  }
  return (w
        ..ctxUnsigned(2, urgent ? 1 : 0)
        ..ctxCharacterString(3, message))
      .toBytes();
}
