import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/types.dart';
import '../models/bacnet_object.dart';
import 'reader.dart';
import 'value_encoding.dart';
import 'values.dart';

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
  final int propertyId;

  /// Array index or -1.
  final int arrayIndex;

  /// Decoded values.
  final List<Object?> values;

  /// Collapsed value (see [collapseValues]).
  Object? get value => collapseValues(values);
}

/// Decodes a ReadProperty-ACK.
ReadPropertyResult decodeReadPropertyAck(Uint8List data) {
  final r = BacnetReader(data);
  final object = r.readContextObjectId(0);
  final propertyId = r.readContextUnsigned(1);
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

/// Decodes a ReadPropertyMultiple-ACK into `'type:instance'` →
/// `propertyId` → value (a [BacnetError] for property access errors).
Map<String, Map<int, dynamic>> decodeReadPropertyMultipleAck(Uint8List data) {
  final r = BacnetReader(data);
  final result = <String, Map<int, dynamic>>{};
  while (!r.isAtEnd) {
    final object = r.readContextObjectId(0);
    final properties = <int, dynamic>{};
    r.expectOpening(1);
    while (!r.nextIsClosing(1)) {
      final propertyId = r.readContextUnsigned(2);
      r.readOptionalContextUnsigned(3);
      if (r.nextIsOpening(4)) {
        r.expectOpening(4);
        properties[propertyId] = collapseValues(r.readValuesUntilClosing(4));
      } else {
        r.expectOpening(5);
        final errorClass = r.readApplicationValue();
        final errorCode = r.readApplicationValue();
        r.expectClosing(5);
        properties[propertyId] = BacnetError(
          errorClass is int ? errorClass : -1,
          errorCode is int ? errorCode : -1,
        );
      }
    }
    r.expectClosing(1);
    result['${object.type}:${object.instance}'] = properties;
  }
  return result;
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
  final int propertyId;

  /// Result flags: bit 0 first-item, bit 1 last-item, bit 2 more-items.
  final BacnetBitString resultFlags;

  /// Number of returned items.
  final int itemCount;

  /// Decoded items (application values or constructed records).
  final List<Object?> items;

  /// Sequence number of the first item (log buffers only).
  final int? firstSequenceNumber;

  /// True when more items are available.
  bool get moreItems => resultFlags[2];
}

/// Decodes a ReadRange-ACK.
ReadRangeResult decodeReadRangeAck(Uint8List data) {
  final r = BacnetReader(data);
  final object = r.readContextObjectId(0);
  final propertyId = r.readContextUnsigned(1);
  r.readOptionalContextUnsigned(2);
  final flags = r.readContextBitString(3);
  final count = r.readContextUnsigned(4);
  var items = const <Object?>[];
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
  final int propertyId;

  /// Array index or -1.
  final int arrayIndex;

  /// Decoded value.
  final Object? value;

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
    final propertyId = r.readContextUnsigned(0);
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
(int, int) decodeComplexError(Uint8List data) {
  final r = BacnetReader(data);
  final wrapped = r.nextIsOpening(0);
  if (wrapped) r.expectOpening(0);
  final errorClass = r.readApplicationValue();
  final errorCode = r.readApplicationValue();
  return (
    errorClass is int ? errorClass : -1,
    errorCode is int ? errorCode : -1,
  );
}
