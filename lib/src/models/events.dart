import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../constants/enumerations.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/types.dart';
import 'alarms.dart';
import 'bacnet_value.dart';
import 'complex_values.dart';

/// Base class of the unsolicited events delivered by the BACnet stack.
///
/// Listen to `BacnetClient.events` for all events or to the typed streams
/// `BacnetClient.iAmEvents`, `BacnetClient.covEvents` and
/// `BacnetServer.writeEvents`. The class is sealed, so a `switch` over the
/// event type is checked for exhaustiveness.
@immutable
sealed class BacnetEvent {
  const BacnetEvent();
}

/// An unexpected error reported by the stack (not tied to a request).
class ErrorEvent extends BacnetEvent {
  /// Creates an error event.
  const ErrorEvent(this.error);

  /// Error message.
  final String error;

  @override
  String toString() => 'ErrorEvent($error)';
}

/// A log message produced by the worker isolate or the native engine.
class LogEvent extends BacnetEvent {
  /// Creates a log event.
  const LogEvent({
    required this.levelIndex,
    required this.message,
    this.errorObj,
    this.stackTrace,
  });

  /// Index of the [BacnetLogLevel].
  final int levelIndex;

  /// Log message.
  final String message;

  /// Error description, if any.
  final String? errorObj;

  /// Stack trace, if any.
  final String? stackTrace;

  /// Severity of the message.
  BacnetLogLevel get level => BacnetLogLevel.values[levelIndex];

  @override
  String toString() => 'LogEvent(${level.name}: $message)';
}

/// An I-Am announcement of a device.
class IAmEvent extends BacnetEvent {
  /// Creates an I-Am event.
  const IAmEvent({
    required this.deviceId,
    required this.net,
    required this.mac,
    required this.len,
    this.maxApdu = 1476,
    this.vendorId = 0,
    this.segmentation = BacnetSegmentation.none,
    this.adr = const [],
  });

  /// Announced device instance.
  final int deviceId;

  /// Source network number (0 = local network).
  final int net;

  /// Source MAC address (BACnet/IP: 4 bytes IPv4 + 2 bytes port).
  final List<int> mac;

  /// Length of the I-Am service data.
  final int len;

  /// Maximum APDU length accepted by the device.
  final int maxApdu;

  /// Vendor identifier.
  final int vendorId;

  /// Segmentation supported (0 both, 1 transmit, 2 receive, 3 none).
  final BacnetSegmentation segmentation;

  /// MAC address of the device behind a router (empty for local devices).
  final List<int> adr;

  /// IPv4 address of the device (or of its router), if BACnet/IP.
  String? get ipAddress =>
      mac.length >= 4 ? '${mac[0]}.${mac[1]}.${mac[2]}.${mac[3]}' : null;

  /// UDP port of the device (or of its router), if BACnet/IP.
  int? get port => mac.length >= 6 ? (mac[4] << 8) | mac[5] : null;

  @override
  String toString() =>
      'IAmEvent(device: $deviceId, ip: $ipAddress, '
      'port: $port, net: $net, maxApdu: $maxApdu, vendor: $vendorId)';
}

/// A Change-of-Value notification.
class CovNotificationEvent extends BacnetEvent {
  /// Creates a COV notification event.
  const CovNotificationEvent({
    required this.objectType,
    required this.instance,
    required this.timestamp,
    this.deviceId = -1,
    this.subscriberProcessId = 0,
    this.timeRemaining = 0,
    this.values = const {},
    this.confirmed = false,
  });

  /// Object type of the monitored object.
  final BacnetObjectType objectType;

  /// Instance of the monitored object.
  final int instance;

  /// Reception time (ISO 8601).
  final String timestamp;

  /// Initiating device instance.
  final int deviceId;

  /// Subscriber process identifier of the subscription.
  final int subscriberProcessId;

  /// Remaining subscription lifetime in seconds (0 = indefinite).
  final int timeRemaining;

  /// Reported property values, typically Present_Value and Status_Flags.
  final Map<BacnetPropertyId, BacnetValue> values;

  /// True for a confirmed notification.
  final bool confirmed;

  /// The monitored object.
  BacnetObject get object => BacnetObject(type: objectType, instance: instance);

  /// The reported Present_Value, if any.
  BacnetValue? get presentValue => values[BacnetPropertyId.presentValue];

  /// The reported Status_Flags, if any.
  BacnetStatusFlags? get statusFlags =>
      values[BacnetPropertyId.statusFlags]?.asStatusFlags;

  @override
  String toString() =>
      'CovNotificationEvent(device: $deviceId, '
      'object: $objectType:$instance, values: $values)';
}

/// A remote client wrote to an object of the local server.
class PropertyWriteEvent extends BacnetEvent {
  /// Creates a property write event.
  const PropertyWriteEvent({
    required this.objectType,
    required this.instance,
    required this.propertyId,
    required this.value,
    this.index = -1,
    this.priority = 16,
    this.rawValue,
  });

  /// Object type written to.
  final BacnetObjectType objectType;

  /// Object instance written to.
  final int instance;

  /// Property identifier written.
  final BacnetPropertyId propertyId;

  /// The written value; null only if [rawValue] could not be decoded.
  ///
  /// A [BacnetNull] relinquished [priority].
  final BacnetValue? value;

  /// Array index written (-1 for the whole property).
  final int index;

  /// Write priority used.
  final int priority;

  /// Application encoded value as received.
  final Uint8List? rawValue;

  @override
  String toString() =>
      'PropertyWriteEvent($objectType:$instance '
      'property $propertyId = $value @ $priority)';
}

/// An I-Have: [deviceId] hosts [object] named [objectName] (the answer to
/// `BacnetClient.sendWhoHas`).
class IHaveEvent extends BacnetEvent {
  /// Creates an I-Have event.
  const IHaveEvent({
    required this.deviceId,
    required this.object,
    required this.objectName,
    this.mac = const [],
    this.net = 0,
  });

  /// Device hosting the object.
  final int deviceId;

  /// The object.
  final BacnetObject object;

  /// Name of the object.
  final String objectName;

  /// Source MAC address.
  final List<int> mac;

  /// Source network number.
  final int net;

  @override
  String toString() => 'IHaveEvent(device: $deviceId, $object "$objectName")';
}

/// An UnconfirmedTextMessage sent to this device.
class TextMessageEvent extends BacnetEvent {
  /// Creates a text message event.
  const TextMessageEvent({
    required this.sourceDeviceId,
    required this.message,
    this.urgent = false,
    this.classNumber,
    this.classText,
  });

  /// Device that sent the message.
  final int sourceDeviceId;

  /// The text.
  final String message;

  /// True for an urgent message (otherwise normal priority).
  final bool urgent;

  /// Numeric message class, if the sender gave one.
  final int? classNumber;

  /// Character message class, if the sender gave one.
  final String? classText;

  @override
  String toString() =>
      'TextMessageEvent(from $sourceDeviceId${urgent ? ', urgent' : ''}: '
      '$message)';
}

/// An UnconfirmedPrivateTransfer: a vendor specific service.
class PrivateTransferEvent extends BacnetEvent {
  /// Creates a private transfer event.
  const PrivateTransferEvent({
    required this.vendorId,
    required this.serviceNumber,
    this.parameters,
    this.mac = const [],
    this.net = 0,
  });

  /// Vendor identifier defining the service.
  final int vendorId;

  /// Vendor specific service number.
  final int serviceNumber;

  /// Service parameters, defined by the vendor.
  final BacnetValue? parameters;

  /// Source MAC address.
  final List<int> mac;

  /// Source network number.
  final int net;

  @override
  String toString() =>
      'PrivateTransferEvent(vendor $vendorId, service $serviceNumber, '
      '$parameters)';
}

/// An alarm or event notification: an object changed its event state, or
/// a transition was acknowledged ([isAckNotification]).
///
/// Devices send notifications to the recipients of the Notification Class
/// of the object (see `BacnetClient.addListElements` and
/// `BacnetProperties.recipientList`). Alarms with [ackRequired] wait for
/// `BacnetClient.acknowledgeEvent`.
class EventNotificationEvent extends BacnetEvent {
  /// Creates an event notification.
  const EventNotificationEvent({
    required this.processId,
    required this.deviceId,
    required this.object,
    required this.timeStamp,
    required this.notificationClass,
    required this.priority,
    required this.eventType,
    required this.notifyType,
    required this.toState,
    this.messageText,
    this.ackRequired = false,
    this.fromState,
    this.eventValues,
    this.confirmed = false,
    this.mac = const [],
    this.net = 0,
  });

  /// Process identifier of the recipient (from its BACnetDestination).
  final int processId;

  /// Device that sent the notification.
  final int deviceId;

  /// The object whose event state changed.
  final BacnetObject object;

  /// When the transition happened.
  final BacnetTimeStamp timeStamp;

  /// Notification Class of the object.
  final int notificationClass;

  /// Priority of the transition (0 highest .. 255 lowest).
  final int priority;

  /// Event algorithm that detected the transition.
  final BacnetEventType eventType;

  /// Optional text describing the event.
  final String? messageText;

  /// Alarm, event or acknowledgement notification.
  final BacnetNotifyType notifyType;

  /// True when the transition must be acknowledged.
  final bool ackRequired;

  /// The previous event state (null for acknowledgement notifications).
  final BacnetEventState? fromState;

  /// The new event state (the acknowledged state for acknowledgement
  /// notifications).
  final BacnetEventState toState;

  /// The values the event algorithm reports (null for acknowledgement
  /// notifications).
  final BacnetEventValues? eventValues;

  /// True for a ConfirmedEventNotification (already acknowledged at the
  /// protocol level, which does not acknowledge the alarm).
  final bool confirmed;

  /// Source MAC address.
  final List<int> mac;

  /// Source network number.
  final int net;

  /// True for the notification that a transition was acknowledged.
  bool get isAckNotification => notifyType == BacnetNotifyType.ackNotification;

  @override
  String toString() =>
      'EventNotificationEvent(device: $deviceId, $object '
      '${fromState?.label ?? ''} -> ${toState.label}, ${notifyType.label}'
      '${ackRequired ? ', ack required' : ''}, $eventValues)';
}

/// A remote client acknowledged an alarm of an object of the local server
/// (AcknowledgeAlarm; only successful acknowledgements).
class AlarmAcknowledgedEvent extends BacnetEvent {
  /// Creates the event.
  const AlarmAcknowledgedEvent({
    required this.processId,
    required this.object,
    required this.eventState,
    required this.timeStamp,
    required this.source,
    required this.timeOfAcknowledgment,
    this.mac = const [],
    this.net = 0,
  });

  /// Acknowledging process of the client.
  final int processId;

  /// The object whose transition was acknowledged.
  final BacnetObject object;

  /// The state of the acknowledged transition.
  final BacnetEventState eventState;

  /// When the acknowledged transition happened.
  final BacnetTimeStamp timeStamp;

  /// Who acknowledged, e.g. the operator.
  final String source;

  /// When the client acknowledged.
  final BacnetTimeStamp timeOfAcknowledgment;

  /// Source MAC address.
  final List<int> mac;

  /// Source network number.
  final int net;

  @override
  String toString() =>
      'AlarmAcknowledgedEvent($object ${eventState.label} by "$source")';
}

/// A remote client added elements to or removed elements from a list
/// property of the local server (AddListElement/RemoveListElement), e.g.
/// the Recipient_List of a Notification Class.
///
/// Servers that keep their configuration persist the changed list:
///
/// ```dart
/// server.listElementEvents
///     .where((e) => e.propertyId == BacnetPropertyId.recipientList)
///     .listen((e) async => save(
///         e.object, await server.read(e.object, BacnetProperties.recipientList)));
/// ```
class ListElementEvent extends BacnetEvent {
  /// Creates the event.
  const ListElementEvent({
    required this.object,
    required this.propertyId,
    required this.added,
    required this.elements,
    this.arrayIndex = -1,
    this.mac = const [],
    this.net = 0,
  });

  /// The object.
  final BacnetObject object;

  /// The list property.
  final BacnetPropertyId propertyId;

  /// Array index of a list in an array, or -1.
  final int arrayIndex;

  /// True for AddListElement, false for RemoveListElement.
  final bool added;

  /// The added or removed elements, one after another (decode them with
  /// the typed property, e.g. `BacnetProperties.recipientList.decode`).
  final BacnetValue elements;

  /// Source MAC address.
  final List<int> mac;

  /// Source network number.
  final int net;

  @override
  String toString() =>
      'ListElementEvent(${added ? 'added to' : 'removed from'} $object '
      '${propertyId.label}: $elements)';
}

/// Any other unconfirmed service request, and requests that could not be
/// decoded.
class UnconfirmedServiceEvent extends BacnetEvent {
  /// Creates an unconfirmed service event.
  const UnconfirmedServiceEvent({
    required this.service,
    required this.data,
    required this.mac,
    required this.net,
    this.confirmed = false,
  });

  /// Service choice (see `BacnetUnconfirmedService`, or
  /// `BacnetConfirmedService` when [confirmed]).
  final int service;

  /// Encoded service request.
  final Uint8List data;

  /// Source MAC address.
  final List<int> mac;

  /// Source network number.
  final int net;

  /// True for a confirmed notification (already acknowledged).
  final bool confirmed;
}

// ---- names used up to 0.0.x ----------------------------------------------

/// Former name of [BacnetEvent].
@Deprecated('Use BacnetEvent')
typedef WorkerResponse = BacnetEvent;

/// Former name of [ErrorEvent].
@Deprecated('Use ErrorEvent')
typedef ErrorResponse = ErrorEvent;

/// Former name of [LogEvent].
@Deprecated('Use LogEvent')
typedef LogResponse = LogEvent;

/// Former name of [IAmEvent].
@Deprecated('Use IAmEvent')
typedef IAmResponse = IAmEvent;

/// Former name of [CovNotificationEvent].
@Deprecated('Use CovNotificationEvent')
typedef COVNotificationResponse = CovNotificationEvent;

/// Former name of [PropertyWriteEvent].
@Deprecated('Use PropertyWriteEvent')
typedef WriteNotificationResponse = PropertyWriteEvent;
