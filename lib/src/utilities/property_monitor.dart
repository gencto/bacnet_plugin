import 'dart:async';

import 'package:bacnet_plugin/bacnet_plugin.dart';

/// Monitors BACnet properties for changes using COV or Polling.
///
/// Provides a unified stream of property updates, abstracting away the underlying
/// mechanism (COV subscription vs. active polling).
class PropertyMonitor {
  /// Creates a property monitor using the provided BACnet client.
  PropertyMonitor(this.client);

  /// The BACnet client used for communication.
  final BacnetClient client;

  // Active monitors keyed by "deviceId:objectType:instance:propertyId"
  final _activeMonitors = <String, StreamController<PropertyUpdate>>{};

  /// Monitors a specific property for changes.
  ///
  /// Attempts to subscribe to Change Of Value (COV) notifications.
  /// If [preferPolling] is true, or if COV is not reliable (logic to be enhanced),
  /// it runs a polling loop with the specified [pollingInterval].
  ///
  /// Returns a stream of [PropertyUpdate] events.
  Stream<PropertyUpdate> monitor({
    required int deviceId,
    required BacnetObject object,
    required int propertyId,
    Duration pollingInterval = const Duration(seconds: 2),
    bool preferPolling = false,
  }) {
    final key = _generateKey(deviceId, object, propertyId);

    // Return existing stream if already monitoring
    if (_activeMonitors.containsKey(key)) {
      return _activeMonitors[key]!.stream;
    }

    final controller = StreamController<PropertyUpdate>.broadcast();
    _activeMonitors[key] = controller;

    Timer? pollingTimer;
    StreamSubscription<dynamic>? eventSubscription;

    void startPolling() {
      pollingTimer?.cancel();
      pollingTimer = Timer.periodic(pollingInterval, (_) async {
        if (controller.isClosed) return;
        try {
          final val = await client.readProperty(
            deviceId,
            object.type,
            object.instance,
            propertyId,
          );
          if (!controller.isClosed) {
            controller.add(
              PropertyUpdate(
                deviceId: deviceId,
                objectIdentifier: object,
                propertyIdentifier: propertyId,
                value: val,
                timestamp: DateTime.now(),
                source: preferPolling
                    ? UpdateSource.manual
                    : UpdateSource.missingCovFallback,
              ),
            );
          }
        } on Object catch (_) {
          if (!controller.isClosed) {
            // Don't error the stream on polling failure, just log or add error update
            // controller.addError(e); // Optional: decide if we want to terminate stream
          }
        }
      });
    }

    void stopPolling() {
      pollingTimer?.cancel();
      pollingTimer = null;
    }

    // Handle stream lifecycle
    controller.onListen = () async {
      // 1. Initial read to get current value immediately
      try {
        final val = await client.readProperty(
          deviceId,
          object.type,
          object.instance,
          propertyId,
        );
        controller.add(
          PropertyUpdate(
            deviceId: deviceId,
            objectIdentifier: object,
            propertyIdentifier: propertyId,
            value: val,
            timestamp: DateTime.now(),
            source: UpdateSource.manual,
          ),
        );
      } on Object catch (e) {
        // Only error if initial read fails? Or just continue?
        controller.addError(e);
      }

      // 2. Subscribe to COV if not strictly polling preferred
      if (!preferPolling) {
        try {
          await client.subscribeCOV(
            deviceId,
            object.type,
            object.instance,
            propId: propertyId,
          );
        } on Object catch (_) {
          // If subscription fails, fallback to polling immediately
          startPolling();
        }
      } else {
        startPolling();
      }

      // 3. Listen for COV notifications
      eventSubscription = client.events.listen((event) {
        if (event is COVNotificationResponse) {
          if (event.deviceId == deviceId &&
              event.objectType == object.type &&
              event.instance == object.instance) {
            // Note: COVNotificationResponse in current model might not carry propertyId/value
            // Depending on the implementation of COVNotificationResponse.
            // Let's check the model definition.
            // If the event doesn't have the value, we might need to read it.

            // Assuming for now we trigger a read or if the event has data.
            // Checking COVNotificationResponse definition...
            // It has objectType, instance, timestamp, deviceId.
            // It DOES NOT seem to have propertyId or value in the current definition seen previously?
            // Wait, I need to check COVNotificationResponse definition again.

            // If it doesn't have value, we must read it.
            client
                .readProperty(
                  deviceId,
                  object.type,
                  object.instance,
                  propertyId,
                )
                .then((val) {
                  if (!controller.isClosed) {
                    controller.add(
                      PropertyUpdate(
                        deviceId: deviceId,
                        objectIdentifier: object,
                        propertyIdentifier: propertyId,
                        value: val,
                        timestamp: DateTime.now(), // or parse event.timestamp
                        source: UpdateSource.cov,
                      ),
                    );
                  }
                });
          }
        }
      });
    };

    controller.onCancel = () async {
      stopPolling();
      await eventSubscription?.cancel();
      _activeMonitors.remove(key);
      await controller.close();
    };

    return controller.stream;
  }

  String _generateKey(int deviceId, BacnetObject object, int propertyId) {
    return '$deviceId:${object.type}:${object.instance}:$propertyId';
  }
}
