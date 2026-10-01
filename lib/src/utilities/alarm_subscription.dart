import '../client/bacnet_client.dart';
import '../constants/errors.dart';
import '../constants/object_types.dart';
import '../core/exceptions.dart';
import '../models/alarms.dart';
import '../models/bacnet_property.dart';
import '../models/bacnet_value.dart';
import '../models/complex_values.dart';
import '../models/events.dart';

/// Subscriptions to the alarms and events of Notification Classes.
extension BacnetAlarmSubscriptions on BacnetClient {
  /// Adds this client to the recipients of Notification Class
  /// [notificationClass] of [deviceId] and returns the subscription, whose
  /// [AlarmSubscription.notifications] are the alarms and events of the
  /// objects that report to that class.
  ///
  /// The recipient is the address of this client ([localAddress]) unless
  /// [recipient] says otherwise (e.g. the address a NAT router forwards);
  /// [processId] distinguishes the subscription from others of this client
  /// (allocated by default). [confirmed] requests confirmed notifications;
  /// [transitions] selects the reported transitions.
  ///
  /// Devices without AddListElement get the destination appended to their
  /// Recipient_List with WriteProperty (read, append, write back; a
  /// concurrent change by another client between read and write is lost).
  ///
  /// ```dart
  /// final alarms = await client.subscribeAlarms(1234, notificationClass: 1);
  /// alarms.notifications.listen((event) async {
  ///   print('${event.object} ${event.toState.label}');
  ///   if (event.ackRequired) {
  ///     await client.acknowledgeEvent(event, source: 'operator');
  ///   }
  /// });
  /// // ...
  /// await alarms.cancel();
  /// ```
  Future<AlarmSubscription> subscribeAlarms(
    int deviceId, {
    required int notificationClass,
    BacnetRecipient? recipient,
    int? processId,
    bool confirmed = false,
    BacnetEventTransitionBits transitions = const BacnetEventTransitionBits(
      toOffNormal: true,
      toFault: true,
      toNormal: true,
    ),
    Duration? timeout,
  }) async {
    final subscription = AlarmSubscription._(
      this,
      deviceId,
      BacnetObject(
        type: BacnetObjectType.notificationClass,
        instance: notificationClass,
      ),
      BacnetDestination(
        recipient: recipient ?? await localAddress(),
        processId: processId ?? allocateProcessId(),
        issueConfirmedNotifications: confirmed,
        transitions: transitions,
      ),
      timeout,
    );
    await subscription._add();
    return subscription;
  }
}

/// This client as a recipient of a Notification Class (see
/// [BacnetAlarmSubscriptions.subscribeAlarms]).
final class AlarmSubscription {
  AlarmSubscription._(
    this.client,
    this.deviceId,
    this.notificationClass,
    this.destination,
    this._timeout,
  );

  /// The client receiving the notifications.
  final BacnetClient client;

  /// The device sending the notifications.
  final int deviceId;

  /// The Notification Class.
  final BacnetObject notificationClass;

  /// The entry of the Recipient_List.
  final BacnetDestination destination;

  final Duration? _timeout;
  bool _cancelled = false;

  /// True after [cancel].
  bool get isCancelled => _cancelled;

  /// The alarm, event and acknowledgement notifications of this
  /// subscription.
  Stream<EventNotificationEvent> get notifications =>
      client.eventNotifications.where(
        (event) =>
            event.deviceId == deviceId &&
            event.notificationClass == notificationClass.instance &&
            event.processId == destination.processId,
      );

  /// The objects of the device that are in alarm or wait for an
  /// acknowledgement (see [BacnetClient.getEventInformation]).
  Future<List<BacnetEventSummary>> eventInformation() =>
      client.getEventInformation(deviceId, timeout: _timeout);

  /// Adds the destination again if the device lost it (e.g. a device that
  /// keeps its Recipient_List in RAM restarted). Returns true when it had
  /// to be added.
  Future<bool> refresh() async {
    _checkActive();
    if ((await _recipients()).contains(destination)) return false;
    await _add();
    return true;
  }

  /// Removes the destination from the Recipient_List; no notifications
  /// arrive afterwards. A destination the device no longer has is not an
  /// error.
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    try {
      await client.removeListElements(
        deviceId,
        notificationClass,
        BacnetProperties.recipientList,
        [destination],
        timeout: _timeout,
      );
    } on BacnetRejectException catch (e) {
      if (e.reason != BacnetRejectReason.unrecognizedService) rethrow;
      final list = await _recipients();
      if (list.contains(destination)) {
        await _write([...list.where((d) => d != destination)]);
      }
    } on BacnetProtocolException catch (e) {
      // already gone (e.g. the device restarted)
      if (e.errorCode != BacnetErrorCode.listElementNotFound) rethrow;
    }
  }

  Future<void> _add() async {
    try {
      await client.addListElements(
        deviceId,
        notificationClass,
        BacnetProperties.recipientList,
        [destination],
        timeout: _timeout,
      );
    } on BacnetRejectException catch (e) {
      if (e.reason != BacnetRejectReason.unrecognizedService) rethrow;
      final list = await _recipients();
      if (!list.contains(destination)) await _write([...list, destination]);
    }
  }

  Future<List<BacnetDestination>> _recipients() => client.read(
    deviceId,
    notificationClass,
    BacnetProperties.recipientList,
    timeout: _timeout,
  );

  Future<void> _write(List<BacnetDestination> list) => client.write(
    deviceId,
    notificationClass,
    BacnetProperties.recipientList,
    list,
    timeout: _timeout,
  );

  void _checkActive() {
    if (_cancelled) throw StateError('the subscription was cancelled');
  }

  @override
  String toString() =>
      'AlarmSubscription(device $deviceId, $notificationClass, $destination)';
}
