import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/types.dart';
import 'bacnet_object.dart';

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
    this.segmentation = 3,
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
  final int segmentation;

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
  final int objectType;

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

  /// Reported property values (property id → value), typically
  /// present-value and status-flags.
  final Map<int, Object?> values;

  /// True for a confirmed notification.
  final bool confirmed;

  /// The monitored object.
  BacnetObject get object => BacnetObject(type: objectType, instance: instance);

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
    this.value,
    this.index = -1,
    this.priority = 16,
    this.rawValue,
  });

  /// Object type written to.
  final int objectType;

  /// Object instance written to.
  final int instance;

  /// Property identifier written.
  final int propertyId;

  /// Decoded written value.
  final Object? value;

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

/// Any other unconfirmed service request or confirmed notification
/// (I-Have, event notifications, text messages, private transfers).
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
