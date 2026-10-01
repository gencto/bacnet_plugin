import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../constants/errors.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import '../models/bacnet_value.dart';
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

/// Extracts error class and code from a complex Error PDU payload
/// (e.g. WritePropertyMultiple-Error, CreateObject-Error).
BacnetError decodeComplexError(Uint8List data) {
  final r = BacnetReader(data);
  if (r.nextIsOpening(0)) r.expectOpening(0);
  return _readError(r);
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
