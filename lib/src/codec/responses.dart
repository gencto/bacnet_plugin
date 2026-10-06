import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../constants/enumerations.dart';
import '../constants/errors.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../constants/services.dart';
import '../core/exceptions.dart';
import '../models/alarms.dart';
import '../models/bacnet_value.dart';
import '../models/channels.dart';
import '../models/complex_values.dart';
import '../models/cov_multiple.dart';
import '../models/events.dart';
import '../models/files.dart';
import 'reader.dart';
import 'value_encoding.dart';

/// Decoded ReadProperty-ACK.
@immutable
class ReadPropertyResult {
  /// Creates a result.
  const ReadPropertyResult({
    required this.object,
    required this.propertyId,
    required this.arrayIndex,
    required this.values,
  });

  /// Object that was read.
  final BacnetObject object;

  /// Property that was read.
  final BacnetPropertyId propertyId;

  /// Array index or -1.
  final int arrayIndex;

  /// Decoded values.
  final List<BacnetValue> values;

  /// The value: a single value, or a [BacnetList] for several values.
  BacnetValue get value => collapseValues(values);
}

/// Decodes a ReadProperty-ACK.
ReadPropertyResult decodeReadPropertyAck(Uint8List data) {
  final r = BacnetReader(data);
  final object = r.readContextObjectId(0);
  final propertyId = BacnetPropertyId(r.readContextUnsigned(1));
  final arrayIndex = r.readOptionalContextUnsigned(2) ?? -1;
  r.expectOpening(3);
  final values = r.readValuesUntilClosing(3);
  return ReadPropertyResult(
    object: object,
    propertyId: propertyId,
    arrayIndex: arrayIndex,
    values: values,
  );
}

/// Decodes a ReadPropertyMultiple-ACK into object → property → value, or
/// a [BacnetError] for property access errors.
Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>
decodeReadPropertyMultipleAck(Uint8List data) {
  final r = BacnetReader(data);
  final result = <BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>{};
  while (!r.isAtEnd) {
    final object = r.readContextObjectId(0);
    final properties = result[object] ??= {};
    r.expectOpening(1);
    while (!r.nextIsClosing(1)) {
      final propertyId = BacnetPropertyId(r.readContextUnsigned(2));
      r.readOptionalContextUnsigned(3);
      if (r.nextIsOpening(4)) {
        r.expectOpening(4);
        properties[propertyId] = collapseValues(r.readValuesUntilClosing(4));
      } else {
        r.expectOpening(5);
        properties[propertyId] = _readError(r);
        r.expectClosing(5);
      }
    }
    r.expectClosing(1);
  }
  return result;
}

/// Reads the error class and code of a BACnetError.
BacnetError _readError(BacnetReader r) {
  final errorClass = r.readApplicationValue().asInt ?? -1;
  final errorCode = r.readApplicationValue().asInt ?? -1;
  return BacnetError(BacnetErrorClass(errorClass), BacnetErrorCode(errorCode));
}

/// Decoded ReadRange-ACK.
@immutable
class ReadRangeResult {
  /// Creates a result.
  const ReadRangeResult({
    required this.object,
    required this.propertyId,
    required this.resultFlags,
    required this.itemCount,
    required this.items,
    this.firstSequenceNumber,
  });

  /// Object that was read.
  final BacnetObject object;

  /// Property that was read.
  final BacnetPropertyId propertyId;

  /// Result flags: bit 0 first-item, bit 1 last-item, bit 2 more-items.
  final BacnetBitString resultFlags;

  /// Number of returned items.
  final int itemCount;

  /// Decoded items (application values or constructed records).
  final List<BacnetValue> items;

  /// Sequence number of the first item (log buffers only).
  final int? firstSequenceNumber;

  /// True when more items are available.
  bool get moreItems => resultFlags[2];
}

/// Decodes a ReadRange-ACK.
ReadRangeResult decodeReadRangeAck(Uint8List data) {
  final r = BacnetReader(data);
  final object = r.readContextObjectId(0);
  final propertyId = BacnetPropertyId(r.readContextUnsigned(1));
  r.readOptionalContextUnsigned(2);
  final flags = r.readContextBitString(3);
  final count = r.readContextUnsigned(4);
  var items = const <BacnetValue>[];
  if (r.nextIsOpening(5)) {
    r.expectOpening(5);
    items = r.readValuesUntilClosing(5);
  }
  final firstSequence = r.readOptionalContextUnsigned(6);
  return ReadRangeResult(
    object: object,
    propertyId: propertyId,
    resultFlags: flags,
    itemCount: count,
    items: items,
    firstSequenceNumber: firstSequence,
  );
}

/// One property value of a COV notification.
@immutable
class CovPropertyValue {
  /// Creates a COV property value.
  const CovPropertyValue({
    required this.propertyId,
    required this.value,
    this.arrayIndex = -1,
    this.priority,
  });

  /// Property identifier.
  final BacnetPropertyId propertyId;

  /// Array index or -1.
  final int arrayIndex;

  /// Decoded value.
  final BacnetValue value;

  /// Priority, if present.
  final int? priority;
}

/// A notification of one object in a COVNotificationMultiple: `values`
/// and, for timestamped references, when they changed.
typedef CovObjectNotification = ({
  BacnetObject object,
  List<CovPropertyValue> values,
  Map<BacnetPropertyId, BacnetTime> changeTimes,
});

/// Decoded COV notification.
@immutable
class CovNotificationData {
  /// Creates a COV notification.
  const CovNotificationData({
    required this.subscriberProcessId,
    required this.initiatingDeviceId,
    required this.monitoredObject,
    required this.timeRemaining,
    required this.values,
  });

  /// Subscriber process identifier of the subscription.
  final int subscriberProcessId;

  /// Device that sent the notification.
  final int initiatingDeviceId;

  /// Monitored object.
  final BacnetObject monitoredObject;

  /// Remaining subscription lifetime in seconds.
  final int timeRemaining;

  /// Reported values.
  final List<CovPropertyValue> values;
}

/// Decodes a (Un)ConfirmedCOVNotification request.
CovNotificationData decodeCovNotification(Uint8List data) {
  final r = BacnetReader(data);
  final pid = r.readContextUnsigned(0);
  final device = r.readContextObjectId(1);
  final object = r.readContextObjectId(2);
  final timeRemaining = r.readContextUnsigned(3);
  r.expectOpening(4);
  final values = <CovPropertyValue>[];
  while (!r.nextIsClosing(4)) {
    final propertyId = BacnetPropertyId(r.readContextUnsigned(0));
    final arrayIndex = r.readOptionalContextUnsigned(1) ?? -1;
    r.expectOpening(2);
    final value = collapseValues(r.readValuesUntilClosing(2));
    final priority = r.readOptionalContextUnsigned(3);
    values.add(
      CovPropertyValue(
        propertyId: propertyId,
        arrayIndex: arrayIndex,
        value: value,
        priority: priority,
      ),
    );
  }
  r.expectClosing(4);
  return CovNotificationData(
    subscriberProcessId: pid,
    initiatingDeviceId: device.instance,
    monitoredObject: object,
    timeRemaining: timeRemaining,
    values: values,
  );
}

/// A decoded complex Error PDU: the error and, for CreateObject,
/// AddListElement and RemoveListElement, the position (1 based) of the
/// element that failed (0 when the request failed for another reason), for
/// SubscribeCOVPropertyMultiple the subscription that failed.
typedef ComplexError = ({
  BacnetError error,
  int? firstFailedElement,
  BacnetFailedCovSubscription? firstFailedSubscription,
});

/// Extracts the error of a complex Error PDU payload of [service] (e.g.
/// WritePropertyMultiple-Error, CreateObject-Error).
ComplexError decodeComplexError(Uint8List data, {int? service}) {
  final r = BacnetReader(data);
  if (!r.nextIsOpening(0)) {
    return (
      error: _readError(r),
      firstFailedElement: null,
      firstFailedSubscription: null,
    );
  }
  r.expectOpening(0);
  final error = _readError(r);
  r.expectClosing(0);
  if (service == BacnetConfirmedService.subscribeCovPropertyMultiple) {
    return (
      error: error,
      firstFailedElement: null,
      firstFailedSubscription: r.nextIsOpening(1)
          ? _failedCovSubscription(r)
          : null,
    );
  }
  final changeList = switch (service) {
    BacnetConfirmedService.createObject ||
    BacnetConfirmedService.addListElement ||
    BacnetConfirmedService.removeListElement => true,
    _ => false,
  };
  return (
    error: error,
    firstFailedElement: changeList ? r.readOptionalContextUnsigned(1) : null,
    firstFailedSubscription: null,
  );
}

BacnetFailedCovSubscription _failedCovSubscription(BacnetReader r) {
  r.expectOpening(1);
  final object = r.readContextObjectId(0);
  r.expectOpening(1);
  final property = BacnetPropertyId(r.readContextUnsigned(0));
  final arrayIndex = r.readOptionalContextUnsigned(1);
  r
    ..expectClosing(1)
    ..expectOpening(2);
  final error = _readError(r);
  r
    ..expectClosing(2)
    ..expectClosing(1);
  return BacnetFailedCovSubscription(
    object: object,
    property: property,
    arrayIndex: arrayIndex,
    errorClass: error.errorClass,
    errorCode: error.errorCode,
  );
}

/// Decoded SubscribeCOVPropertyMultiple request.
typedef SubscribeCovPropertyMultipleData = ({
  int subscriberProcessId,
  bool? confirmed,
  int? lifetime,
  int? maxNotificationDelay,
  List<BacnetCovSubscriptionSpecification> specifications,
});

/// Decodes a SubscribeCOVPropertyMultiple request (ASHRAE 135 clause
/// 13.16).
SubscribeCovPropertyMultipleData decodeSubscribeCovPropertyMultiple(
  Uint8List data,
) {
  final r = BacnetReader(data);
  final pid = r.readContextUnsigned(0);
  final confirmed = r.nextIsContext(1) ? r.readContextBoolean(1) : null;
  final lifetime = r.readOptionalContextUnsigned(2);
  final delay = r.readOptionalContextUnsigned(3);
  r.expectOpening(4);
  final specifications = <BacnetCovSubscriptionSpecification>[];
  while (!r.nextIsClosing(4)) {
    final object = r.readContextObjectId(0);
    r.expectOpening(1);
    final references = <BacnetCovReference>[];
    while (!r.nextIsClosing(1)) {
      r.expectOpening(0);
      final property = BacnetPropertyId(r.readContextUnsigned(0));
      final arrayIndex = r.readOptionalContextUnsigned(1);
      r.expectClosing(0);
      final increment = r.nextIsContext(1) ? r.readContextReal(1) : null;
      references.add(
        BacnetCovReference(
          property,
          arrayIndex: arrayIndex,
          covIncrement: increment,
          timestamped: r.readContextBoolean(2),
        ),
      );
    }
    r.expectClosing(1);
    if (references.isEmpty) {
      throw const BacnetDecodeException('COV subscription without references');
    }
    specifications.add(BacnetCovSubscriptionSpecification(object, references));
  }
  r.expectClosing(4);
  return (
    subscriberProcessId: pid,
    confirmed: confirmed,
    lifetime: lifetime,
    maxNotificationDelay: delay,
    specifications: List.unmodifiable(specifications),
  );
}

/// Decoded COVNotificationMultiple request.
typedef CovNotificationMultipleData = ({
  int subscriberProcessId,
  int initiatingDeviceId,
  int timeRemaining,
  BacnetDateTime? timestamp,
  List<CovObjectNotification> notifications,
});

/// Decodes a (Confirmed or Unconfirmed)COVNotificationMultiple request
/// (ASHRAE 135 clause 13.17).
CovNotificationMultipleData decodeCovNotificationMultiple(Uint8List data) {
  final r = BacnetReader(data);
  final pid = r.readContextUnsigned(0);
  final device = r.readContextObjectId(1);
  final timeRemaining = r.readContextUnsigned(2);
  BacnetDateTime? timestamp;
  if (r.nextIsOpening(3)) {
    r.expectOpening(3);
    timestamp = switch ((r.readApplicationValue(), r.readApplicationValue())) {
      (final BacnetDate date, final BacnetTime time) => BacnetDateTime(
        date,
        time,
      ),
      final other => throw BacnetDecodeException('malformed timestamp $other'),
    };
    r.expectClosing(3);
  }
  r.expectOpening(4);
  final notifications = <CovObjectNotification>[];
  while (!r.nextIsClosing(4)) {
    final object = r.readContextObjectId(0);
    r.expectOpening(1);
    final values = <CovPropertyValue>[];
    final changeTimes = <BacnetPropertyId, BacnetTime>{};
    while (!r.nextIsClosing(1)) {
      final propertyId = BacnetPropertyId(r.readContextUnsigned(0));
      final arrayIndex = r.readOptionalContextUnsigned(1) ?? -1;
      r.expectOpening(2);
      values.add(
        CovPropertyValue(
          propertyId: propertyId,
          arrayIndex: arrayIndex,
          value: collapseValues(r.readValuesUntilClosing(2)),
        ),
      );
      if (r.nextIsContext(3)) {
        final tag = r.readTag();
        if (tag.length != 4) {
          throw const BacnetDecodeException('time of change needs 4 octets');
        }
        int? field(int octet) => octet == 0xFF ? null : octet;
        final octets = r.readBytes(4);
        changeTimes[propertyId] = BacnetTime(
          hour: field(octets[0]),
          minute: field(octets[1]),
          second: field(octets[2]),
          hundredths: field(octets[3]),
        );
      }
    }
    r.expectClosing(1);
    notifications.add((
      object: object,
      values: List.unmodifiable(values),
      changeTimes: Map.unmodifiable(changeTimes),
    ));
  }
  r.expectClosing(4);
  return (
    subscriberProcessId: pid,
    initiatingDeviceId: device.instance,
    timeRemaining: timeRemaining,
    timestamp: timestamp,
    notifications: List.unmodifiable(notifications),
  );
}

/// Decoded I-Have.
typedef IHaveData = ({BacnetObject device, BacnetObject object, String name});

/// Decodes an I-Have request (ASHRAE 135 clause 16.8).
IHaveData decodeIHave(Uint8List data) {
  final r = BacnetReader(data);
  final device = r.readApplicationValue();
  final object = r.readApplicationValue();
  final name = r.readApplicationValue();
  if ((device, object, name) case (
    final BacnetObject device,
    final BacnetObject object,
    BacnetCharacterString(value: final name),
  )) {
    return (device: device, object: object, name: name);
  }
  throw const BacnetDecodeException('malformed I-Have');
}

/// Decoded (Unconfirmed)TextMessage.
typedef TextMessageData = ({
  BacnetObject source,
  int? classNumber,
  String? classText,
  bool urgent,
  String message,
});

/// Decodes a TextMessage request (ASHRAE 135 clause 16.5).
TextMessageData decodeTextMessage(Uint8List data) {
  final r = BacnetReader(data);
  final source = r.readContextObjectId(0);
  int? classNumber;
  String? classText;
  if (r.nextIsOpening(1)) {
    r.expectOpening(1);
    if (r.nextIsContext(0)) {
      classNumber = r.readContextUnsigned(0);
    } else {
      classText = r.readContextCharacterString(1);
    }
    r.expectClosing(1);
  }
  final priority = r.readContextUnsigned(2);
  final message = r.readContextCharacterString(3);
  return (
    source: source,
    classNumber: classNumber,
    classText: classText,
    urgent: priority == 1,
    message: message,
  );
}

/// Decoded (Unconfirmed)PrivateTransfer.
typedef PrivateTransferData = ({
  int vendorId,
  int serviceNumber,
  BacnetValue? parameters,
});

/// Decodes a PrivateTransfer request (ASHRAE 135 clause 16.2).
PrivateTransferData decodePrivateTransfer(Uint8List data) {
  final r = BacnetReader(data);
  final vendorId = r.readContextUnsigned(0);
  final serviceNumber = r.readContextUnsigned(1);
  BacnetValue? parameters;
  if (r.nextIsOpening(2)) {
    r.expectOpening(2);
    parameters = collapseValues(r.readValuesUntilClosing(2));
  }
  return (
    vendorId: vendorId,
    serviceNumber: serviceNumber,
    parameters: parameters,
  );
}

/// Decodes a (Un)ConfirmedEventNotification request (ASHRAE 135 clause
/// 13.8).
///
/// Event values that do not match their algorithm are returned as
/// [BacnetOtherEventValues] rather than dropping the notification.
EventNotificationEvent decodeEventNotification(
  Uint8List data, {
  bool confirmed = false,
  List<int> mac = const [],
  int net = 0,
}) {
  final r = BacnetReader(data);
  final processId = r.readContextUnsigned(0);
  final device = r.readContextObjectId(1);
  final object = r.readContextObjectId(2);
  final timeStamp = _readTimeStamp(r, 3);
  final notificationClass = r.readContextUnsigned(4);
  final priority = r.readContextUnsigned(5);
  final eventType = BacnetEventType(r.readContextUnsigned(6));
  final messageText = r.nextIsContext(7)
      ? r.readContextCharacterString(7)
      : null;
  final notifyType = BacnetNotifyType(r.readContextUnsigned(8));
  final ackRequired = r.nextIsContext(9) && r.readContextBoolean(9);
  final fromState = r.readOptionalContextUnsigned(10);
  final toState = BacnetEventState(r.readContextUnsigned(11));
  BacnetEventValues? eventValues;
  if (r.nextIsOpening(12)) {
    r.expectOpening(12);
    final choice = r.readValuesUntilClosing(12);
    if (choice case [final BacnetConstructedValue values]) {
      try {
        eventValues = BacnetEventValues.fromValue(values);
      } on BacnetDecodeException {
        eventValues = BacnetOtherEventValues(
          BacnetEventType(values.tag),
          values.values,
        );
      }
    } else {
      throw BacnetDecodeException('malformed event values: $choice');
    }
  }
  return EventNotificationEvent(
    processId: processId,
    deviceId: device.instance,
    object: object,
    timeStamp: timeStamp,
    notificationClass: notificationClass,
    priority: priority,
    eventType: eventType,
    messageText: messageText,
    notifyType: notifyType,
    ackRequired: ackRequired,
    fromState: fromState == null ? null : BacnetEventState(fromState),
    toState: toState,
    eventValues: eventValues,
    confirmed: confirmed,
    mac: mac,
    net: net,
  );
}

BacnetTimeStamp _readTimeStamp(BacnetReader r, int tag) {
  r.expectOpening(tag);
  return switch (r.readValuesUntilClosing(tag)) {
    [final choice] => BacnetTimeStamp.fromValue(choice),
    final other => throw BacnetDecodeException('malformed time stamp: $other'),
  };
}

/// Decoded GetEventInformation-ACK.
typedef EventInformation = ({
  List<BacnetEventSummary> summaries,
  bool moreEvents,
});

/// Decodes a GetEventInformation-ACK (ASHRAE 135 clause 13.12).
EventInformation decodeGetEventInformationAck(Uint8List data) {
  final r = BacnetReader(data);
  final summaries = <BacnetEventSummary>[];
  r.expectOpening(0);
  while (!r.nextIsClosing(0)) {
    final object = r.readContextObjectId(0);
    final state = BacnetEventState(r.readContextUnsigned(1));
    final acked = BacnetEventTransitionBits.fromValue(
      r.readContextBitString(2),
    );
    r.expectOpening(3);
    final stamps = r
        .readValuesUntilClosing(3)
        .map(BacnetTimeStamp.fromValue)
        .toList();
    final notifyType = BacnetNotifyType(r.readContextUnsigned(4));
    final enable = BacnetEventTransitionBits.fromValue(
      r.readContextBitString(5),
    );
    r.expectOpening(6);
    final priorities = [
      for (final value in r.readValuesUntilClosing(6))
        switch (value) {
          BacnetUnsigned(:final value) => value,
          _ => throw BacnetDecodeException('malformed priority: $value'),
        },
    ];
    summaries.add(
      BacnetEventSummary(
        object: object,
        eventState: state,
        acknowledgedTransitions: acked,
        eventTimeStamps: List.unmodifiable(stamps),
        notifyType: notifyType,
        eventEnable: enable,
        eventPriorities: List.unmodifiable(priorities),
      ),
    );
  }
  r.expectClosing(0);
  final more = r.readContextBoolean(1);
  return (summaries: List.unmodifiable(summaries), moreEvents: more);
}

/// Decodes a GetAlarmSummary-ACK (ASHRAE 135 clause 13.10).
List<BacnetAlarmSummary> decodeGetAlarmSummaryAck(Uint8List data) {
  final r = BacnetReader(data);
  final result = <BacnetAlarmSummary>[];
  while (!r.isAtEnd) {
    final object = r.readApplicationValue();
    final state = r.readApplicationValue();
    final acked = r.readApplicationValue();
    if ((object, state, acked) case (
      final BacnetObject object,
      BacnetEnumerated(value: final state),
      final BacnetBitString acked,
    )) {
      result.add(
        BacnetAlarmSummary(
          object: object,
          alarmState: BacnetEventState(state),
          acknowledgedTransitions: BacnetEventTransitionBits.fromValue(acked),
        ),
      );
    } else {
      throw BacnetDecodeException(
        'malformed alarm summary: $object $state $acked',
      );
    }
  }
  return List.unmodifiable(result);
}

/// Decoded AcknowledgeAlarm request.
typedef AcknowledgeAlarmData = ({
  int processId,
  BacnetObject object,
  BacnetEventState eventState,
  BacnetTimeStamp timeStamp,
  String source,
  BacnetTimeStamp timeOfAcknowledgment,
});

/// Decodes an AcknowledgeAlarm request (ASHRAE 135 clause 13.5).
AcknowledgeAlarmData decodeAcknowledgeAlarm(Uint8List data) {
  final r = BacnetReader(data);
  return (
    processId: r.readContextUnsigned(0),
    object: r.readContextObjectId(1),
    eventState: BacnetEventState(r.readContextUnsigned(2)),
    timeStamp: _readTimeStamp(r, 3),
    source: r.readContextCharacterString(4),
    timeOfAcknowledgment: _readTimeStamp(r, 5),
  );
}

/// Decoded AddListElement or RemoveListElement request.
typedef ListElementsData = ({
  BacnetObject object,
  BacnetPropertyId propertyId,
  int arrayIndex,
  BacnetValue elements,
});

/// Decodes an AddListElement or RemoveListElement request (ASHRAE 135
/// clauses 15.1 and 15.2); the elements one after another.
ListElementsData decodeListElements(Uint8List data) {
  final r = BacnetReader(data);
  final object = r.readContextObjectId(0);
  final propertyId = BacnetPropertyId(r.readContextUnsigned(1));
  final arrayIndex = r.readOptionalContextUnsigned(2) ?? -1;
  r.expectOpening(3);
  final elements = r.readValuesUntilClosing(3);
  return (
    object: object,
    propertyId: propertyId,
    arrayIndex: arrayIndex,
    elements: BacnetList(List.unmodifiable(elements)),
  );
}

/// Decodes a CreateObject-ACK: the created object.
BacnetObject decodeCreateObjectAck(Uint8List data) {
  final r = BacnetReader(data);
  if (r.readApplicationValue() case final BacnetObject object when r.isAtEnd) {
    return object;
  }
  throw const BacnetDecodeException('malformed CreateObject-ACK');
}

/// Decoded AtomicReadFile-ACK: a chunk (stream access) or records.
typedef AtomicReadFileData = ({
  BacnetFileChunk? chunk,
  BacnetFileRecords? records,
});

/// Decodes an AtomicReadFile-ACK (ASHRAE 135 clause 14.1).
AtomicReadFileData decodeAtomicReadFileAck(Uint8List data) {
  final r = BacnetReader(data);
  final endOfFile = switch (r.readApplicationValue()) {
    BacnetBoolean(:final value) => value,
    final other => throw BacnetDecodeException('malformed end of file: $other'),
  };
  int signed() => switch (r.readApplicationValue()) {
    BacnetSigned(:final value) => value,
    BacnetUnsigned(:final value) => value,
    final other => throw BacnetDecodeException('malformed position: $other'),
  };
  Uint8List octets() => switch (r.readApplicationValue()) {
    BacnetOctetString(:final value) => value,
    final other => throw BacnetDecodeException('malformed file data: $other'),
  };
  if (r.nextIsOpening(0)) {
    r.expectOpening(0);
    final start = signed();
    final data = octets();
    r.expectClosing(0);
    return (
      chunk: BacnetFileChunk(start: start, data: data, endOfFile: endOfFile),
      records: null,
    );
  }
  r.expectOpening(1);
  final start = signed();
  final count = switch (r.readApplicationValue()) {
    BacnetUnsigned(:final value) => value,
    final other => throw BacnetDecodeException(
      'malformed record count: $other',
    ),
  };
  final records = [for (var i = 0; i < count; i++) octets()];
  r.expectClosing(1);
  return (
    chunk: null,
    records: BacnetFileRecords(
      start: start,
      records: records,
      endOfFile: endOfFile,
    ),
  );
}

/// Decodes an AtomicWriteFile-ACK: the position (stream access) or record
/// where the data was written.
int decodeAtomicWriteFileAck(Uint8List data) {
  final r = BacnetReader(data);
  final start = r.nextIsContext(0)
      ? r.readContextSigned(0)
      : r.readContextSigned(1);
  return start;
}

/// Decoded AtomicWriteFile request: `data` for stream access, `records`
/// for record access.
typedef AtomicWriteFileRequest = ({
  BacnetObject file,
  int start,
  Uint8List? data,
  List<Uint8List>? records,
});

/// Decodes an AtomicWriteFile request (ASHRAE 135 clause 14.2).
AtomicWriteFileRequest decodeAtomicWriteFile(Uint8List data) {
  final r = BacnetReader(data);
  final file = switch (r.readApplicationValue()) {
    final BacnetObject object => object,
    final other => throw BacnetDecodeException('malformed file: $other'),
  };
  int signed() => switch (r.readApplicationValue()) {
    BacnetSigned(:final value) => value,
    BacnetUnsigned(:final value) => value,
    final other => throw BacnetDecodeException('malformed position: $other'),
  };
  Uint8List octets() => switch (r.readApplicationValue()) {
    BacnetOctetString(:final value) => value,
    final other => throw BacnetDecodeException('malformed file data: $other'),
  };
  if (r.nextIsOpening(0)) {
    r.expectOpening(0);
    final start = signed();
    final octetString = octets();
    r.expectClosing(0);
    return (file: file, start: start, data: octetString, records: null);
  }
  r.expectOpening(1);
  final start = signed();
  final count = switch (r.readApplicationValue()) {
    BacnetUnsigned(:final value) => value,
    final other => throw BacnetDecodeException(
      'malformed record count: $other',
    ),
  };
  final records = [for (var i = 0; i < count; i++) octets()];
  r.expectClosing(1);
  return (file: file, start: start, data: null, records: records);
}

/// Decoded Who-Am-I request.
typedef WhoAmIData = ({int vendorId, String modelName, String serialNumber});

/// Decodes a Who-Am-I request (ASHRAE 135 clause 16.11).
WhoAmIData decodeWhoAmI(Uint8List data) {
  final r = BacnetReader(data);
  return (
    vendorId: _identityUnsigned(r),
    modelName: _identityString(r, 'model name'),
    serialNumber: _identityString(r, 'serial number'),
  );
}

/// Decoded You-Are request.
typedef YouAreData = ({
  int vendorId,
  String modelName,
  String serialNumber,
  int? deviceId,
  Uint8List? macAddress,
});

/// Decodes a You-Are request (ASHRAE 135 clause 16.12).
YouAreData decodeYouAre(Uint8List data) {
  final r = BacnetReader(data);
  final vendorId = _identityUnsigned(r);
  final modelName = _identityString(r, 'model name');
  final serialNumber = _identityString(r, 'serial number');
  int? deviceId;
  Uint8List? macAddress;
  if (!r.isAtEnd) {
    switch (r.readApplicationValue()) {
      case BacnetObject(:final type, :final instance)
          when type == BacnetObjectType.device:
        deviceId = instance;
      case BacnetOctetString(:final value):
        macAddress = value;
      case final other:
        throw BacnetDecodeException('malformed You-Are: $other');
    }
  }
  if (macAddress == null && !r.isAtEnd) {
    macAddress = switch (r.readApplicationValue()) {
      BacnetOctetString(:final value) => value,
      final other => throw BacnetDecodeException('malformed MAC: $other'),
    };
  }
  if (deviceId == null && macAddress == null) {
    throw const BacnetDecodeException('You-Are without device or MAC');
  }
  return (
    vendorId: vendorId,
    modelName: modelName,
    serialNumber: serialNumber,
    deviceId: deviceId,
    macAddress: macAddress,
  );
}

int _identityUnsigned(BacnetReader r) => switch (r.readApplicationValue()) {
  BacnetUnsigned(:final value) when value <= 0xFFFF => value,
  final other => throw BacnetDecodeException('malformed vendor id: $other'),
};

String _identityString(BacnetReader r, String what) =>
    switch (r.readApplicationValue()) {
      BacnetCharacterString(:final value) => value,
      final other => throw BacnetDecodeException('malformed $what: $other'),
    };

/// Decoded WriteGroup request.
typedef WriteGroupData = ({
  int groupNumber,
  int writePriority,
  List<BacnetGroupChannelValue> changes,
  bool? inhibitDelay,
});

/// Decodes a WriteGroup request (ASHRAE 135 clause 15.11).
WriteGroupData decodeWriteGroup(Uint8List data) {
  final r = BacnetReader(data);
  final groupNumber = r.readContextUnsigned(0);
  final writePriority = r.readContextUnsigned(1);
  if (writePriority < 1 || writePriority > 16) {
    throw BacnetDecodeException('write priority $writePriority');
  }
  r.expectOpening(2);
  final changes = <BacnetGroupChannelValue>[];
  while (!r.nextIsClosing(2)) {
    final channel = r.readContextUnsigned(0);
    final priority = r.readOptionalContextUnsigned(1);
    r.expectOpening(2);
    final values = r.readValuesUntilClosing(2);
    if (values.length != 1 ||
        channel > 0xFFFF ||
        (priority != null && (priority < 1 || priority > 16))) {
      throw const BacnetDecodeException('malformed BACnetGroupChannelValue');
    }
    changes.add(
      BacnetGroupChannelValue(
        channel,
        values.single,
        overridingPriority: priority,
      ),
    );
  }
  r.expectClosing(2);
  final inhibitDelay = r.nextIsContext(3) ? r.readContextBoolean(3) : null;
  return (
    groupNumber: groupNumber,
    writePriority: writePriority,
    changes: List.unmodifiable(changes),
    inhibitDelay: inhibitDelay,
  );
}

/// Decoded DeviceCommunicationControl request.
typedef DeviceCommunicationControlData = ({
  BacnetCommunicationState state,
  Duration? duration,
  String? password,
});

/// Decodes a DeviceCommunicationControl request (ASHRAE 135 clause 16.1).
DeviceCommunicationControlData decodeDeviceCommunicationControl(
  Uint8List data,
) {
  final r = BacnetReader(data);
  final minutes = r.readOptionalContextUnsigned(0);
  final state = BacnetCommunicationState(r.readContextUnsigned(1));
  final password = r.nextIsContext(2) ? r.readContextCharacterString(2) : null;
  return (
    state: state,
    duration: minutes == null ? null : Duration(minutes: minutes),
    password: password,
  );
}

/// Decoded ReinitializeDevice request.
typedef ReinitializeDeviceData = ({
  BacnetReinitializedState state,
  String? password,
});

/// Decodes a ReinitializeDevice request (ASHRAE 135 clause 16.4).
ReinitializeDeviceData decodeReinitializeDevice(Uint8List data) {
  final r = BacnetReader(data);
  final state = BacnetReinitializedState(r.readContextUnsigned(0));
  final password = r.nextIsContext(1) ? r.readContextCharacterString(1) : null;
  return (state: state, password: password);
}
