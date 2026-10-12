/// @docImport '../client/bacnet_client.dart';
library;

import 'package:meta/meta.dart';

import '../constants/enumerations.dart';
import 'bacnet_value.dart';

// Typed forms of the datatypes of GetEnrollmentSummary (ASHRAE 135 clause
// 13.12): the filters that select the enrolled events and a summary of one
// of them.

/// Which events a GetEnrollmentSummary request selects by their
/// acknowledgement state (the acknowledgmentFilter of ASHRAE 135 clause
/// 13.12).
enum BacnetAcknowledgmentFilter {
  /// All events, acknowledged or not.
  all,

  /// Only acknowledged events.
  acked,

  /// Only events that are not acknowledged.
  notAcked;

  /// The encoded value (0 all, 1 acked, 2 not-acked).
  int get value => index;
}

/// Which events a GetEnrollmentSummary request selects by their event state
/// (the eventStateFilter of ASHRAE 135 clause 13.12).
enum BacnetEventStateFilter {
  /// Events in an off-normal state.
  offnormal,

  /// Events in fault.
  fault,

  /// Events in a normal state.
  normal,

  /// Events in any state.
  all,

  /// Events in an active state (anything but normal).
  active;

  /// The encoded value (0..4).
  int get value => index;
}

/// An object enrolled in event reporting (an entry of the
/// GetEnrollmentSummary answer, ASHRAE 135 clause 13.12).
@immutable
final class BacnetEnrollmentSummary {
  /// Creates a summary.
  const BacnetEnrollmentSummary({
    required this.object,
    required this.eventType,
    required this.eventState,
    required this.priority,
    this.notificationClass,
  });

  /// The object.
  final BacnetObject object;

  /// The event type (algorithm) the object is enrolled in.
  final BacnetEventType eventType;

  /// Its event state.
  final BacnetEventState eventState;

  /// The priority of its last event transition.
  final int priority;

  /// The Notification Class the object reports to, if the device gives one.
  final int? notificationClass;

  @override
  bool operator ==(Object other) =>
      other is BacnetEnrollmentSummary &&
      other.object == object &&
      other.eventType == eventType &&
      other.eventState == eventState &&
      other.priority == priority &&
      other.notificationClass == notificationClass;

  @override
  int get hashCode =>
      Object.hash(object, eventType, eventState, priority, notificationClass);

  @override
  String toString() =>
      'BacnetEnrollmentSummary($object ${eventType.label} '
      '${eventState.label}, priority $priority'
      '${notificationClass == null ? '' : ', class $notificationClass'})';
}
