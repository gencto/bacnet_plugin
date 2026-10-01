// Monitor controllers are closed in onCancel when the last listener leaves.
// ignore_for_file: close_sinks

import 'dart:async';

import '../client/bacnet_client.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import '../core/types.dart';
import '../models/bacnet_value.dart';
import '../models/events.dart';
import '../models/property_update.dart';

/// Monitors BACnet properties using COV subscriptions with polling fallback.
///
/// Subscriptions are renewed before their lifetime expires and cancelled
/// when the last listener of a stream goes away. COV notifications carry
/// the new value, so no extra read is needed per change. When a device
/// rejects the subscription the monitor polls with `pollingInterval`.
///
/// ```dart
/// final monitor = PropertyMonitor(client);
/// monitor
///     .monitor(
///       deviceId: 1234,
///       object: const BacnetObject(
///         type: BacnetObjectType.analogInput,
///         instance: 1,
///       ),
///       propertyId: BacnetPropertyId.presentValue,
///     )
///     .listen((update) {
///       switch (update) {
///         case PropertyValueUpdate(:final value, :final source):
///           print('$value (${source.name})');
///         case PropertyErrorUpdate(:final error):
///           print('read failed: $error');
///       }
///     });
/// ```
class PropertyMonitor {
  /// Creates a property monitor using the provided BACnet client.
  PropertyMonitor(
    this.client, {
    this.subscriptionLifetime = const Duration(minutes: 5),
  });

  /// The BACnet client used for communication.
  final BacnetClient client;

  /// Lifetime requested for COV subscriptions (renewed at 75 %).
  final Duration subscriptionLifetime;

  final _activeMonitors = <String, StreamController<PropertyUpdate>>{};

  /// Number of active monitors.
  int get activeCount => _activeMonitors.length;

  /// Monitors a property and returns a broadcast stream of updates.
  ///
  /// Calling [monitor] again for the same property returns the same stream.
  Stream<PropertyUpdate> monitor({
    required int deviceId,
    required BacnetObject object,
    required BacnetPropertyId propertyId,
    Duration pollingInterval = const Duration(seconds: 2),
    bool preferPolling = false,
    bool confirmed = false,
  }) {
    final key = '$deviceId:${object.type}:${object.instance}:$propertyId';
    final existing = _activeMonitors[key];
    if (existing != null) return existing.stream;

    final controller = StreamController<PropertyUpdate>.broadcast();
    _activeMonitors[key] = controller;

    final processId = client.allocateProcessId();
    Timer? pollingTimer;
    Timer? renewTimer;
    StreamSubscription<CovNotificationEvent>? covSubscription;
    var subscribed = false;
    var polling = false;
    var closed = false;

    void emit(PropertyUpdate update) {
      if (closed || controller.isClosed) return;
      controller.add(update);
    }

    void emitValue(BacnetValue value, UpdateSource source) => emit(
      PropertyValueUpdate(
        deviceId: deviceId,
        objectIdentifier: object,
        propertyIdentifier: propertyId,
        value: value,
        timestamp: DateTime.now(),
        source: source,
      ),
    );

    Future<void> poll(UpdateSource source) async {
      try {
        final value = await client.readProperty(
          deviceId,
          object.type,
          object.instance,
          propertyId,
        );
        emitValue(value, source);
      } on BacnetException catch (error) {
        emit(
          PropertyErrorUpdate(
            deviceId: deviceId,
            objectIdentifier: object,
            propertyIdentifier: propertyId,
            error: error,
            timestamp: DateTime.now(),
            source: source,
          ),
        );
      }
    }

    void startPolling() {
      if (polling || closed) return;
      polling = true;
      final source = preferPolling
          ? UpdateSource.manual
          : UpdateSource.missingCovFallback;
      var busy = false;
      pollingTimer = Timer.periodic(pollingInterval, (_) async {
        if (busy) return; // never stack reads on a slow device
        busy = true;
        try {
          await poll(source);
        } finally {
          busy = false;
        }
      });
    }

    Future<bool> subscribe() async {
      try {
        await client.subscribeCOV(
          deviceId,
          object.type,
          object.instance,
          propId: propertyId,
          processId: processId,
          lifetime: subscriptionLifetime,
          confirmed: confirmed,
        );
        return true;
      } on BacnetException catch (e) {
        client.log(
          BacnetLogLevel.info,
          'COV subscription to $deviceId/${object.type}:${object.instance} '
          'failed, polling instead',
          e,
        );
        return false;
      }
    }

    void scheduleRenewal() {
      final renewIn = Duration(
        milliseconds: subscriptionLifetime.inMilliseconds * 3 ~/ 4,
      );
      renewTimer = Timer(renewIn, () async {
        if (closed) return;
        if (await subscribe()) {
          scheduleRenewal();
        } else {
          subscribed = false;
          startPolling();
        }
      });
    }

    controller.onListen = () async {
      covSubscription = client.covEvents.listen((event) {
        if (event.deviceId != deviceId ||
            event.objectType != object.type ||
            event.instance != object.instance ||
            event.subscriberProcessId != processId) {
          return;
        }
        if (event.values[propertyId] case final value?) {
          emitValue(value, UpdateSource.cov);
        }
      });

      await poll(UpdateSource.manual);
      if (closed) return;

      if (preferPolling) {
        startPolling();
        return;
      }
      subscribed = await subscribe();
      if (closed) return;
      if (subscribed) {
        scheduleRenewal();
      } else {
        startPolling();
      }
    };

    controller.onCancel = () async {
      closed = true;
      pollingTimer?.cancel();
      renewTimer?.cancel();
      await covSubscription?.cancel();
      _activeMonitors.remove(key);
      if (subscribed) {
        try {
          await client.unsubscribeCOV(
            deviceId,
            object.type,
            object.instance,
            propId: propertyId,
            processId: processId,
          );
        } on BacnetException {
          // the subscription expires on its own
        }
      }
      await controller.close();
    };

    return controller.stream;
  }

  /// Monitors the present value of an object.
  Stream<PropertyUpdate> monitorPresentValue(
    int deviceId,
    BacnetObject object,
  ) => monitor(
    deviceId: deviceId,
    object: object,
    propertyId: BacnetPropertyId.presentValue,
  );
}
