// Monitor controllers are closed in onCancel when the last listener leaves.
// ignore_for_file: close_sinks

import 'dart:async';

import '../client/bacnet_client.dart';
import '../codec/requests.dart';
import '../constants/enumerations.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import '../core/types.dart';
import '../models/bacnet_property.dart';
import '../models/bacnet_value.dart';
import '../models/cov_multiple.dart';
import '../models/events.dart';
import '../models/property_update.dart';

/// Monitors BACnet properties using COV subscriptions with polling fallback.
///
/// Subscriptions are renewed before their lifetime expires and cancelled
/// when the last listener of a stream goes away. COV notifications carry
/// the new value, so no extra read is needed per change. When a device
/// rejects the subscription the monitor polls with `pollingInterval`.
///
/// Devices that execute SubscribeCOVPropertyMultiple (Protocol_Services_
/// Supported) get one subscription for all monitored properties instead of
/// one per property ([useCovMultiple]); properties the device refuses that
/// way fall back to SubscribeCOV(Property) and polling.
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
    this.useCovMultiple = true,
  });

  /// The BACnet client used for communication.
  final BacnetClient client;

  /// Lifetime requested for COV subscriptions (renewed at 75 %).
  final Duration subscriptionLifetime;

  /// Whether the properties of a device that executes
  /// SubscribeCOVPropertyMultiple share one subscription.
  final bool useCovMultiple;

  final _activeMonitors = <String, StreamController<PropertyUpdate>>{};
  final _groups = <String, _CovGroup>{};
  final _covMultipleSupport = <int, Future<bool>>{};

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
    _CovGroup? group;
    _CovGroupEntry? groupEntry;
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

    /// Subscribes to this property alone, or polls.
    Future<void> subscribeAlone() async {
      subscribed = await subscribe();
      if (closed) return;
      if (subscribed) {
        scheduleRenewal();
      } else {
        startPolling();
      }
    }

    controller.onListen = () async {
      covSubscription = client.covEvents.listen((event) {
        if (event.deviceId != deviceId ||
            event.objectType != object.type ||
            event.instance != object.instance ||
            (event.subscriberProcessId != processId &&
                (groupEntry == null ||
                    event.subscriberProcessId != group?.processId))) {
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
      if (useCovMultiple && await _supportsCovMultiple(deviceId)) {
        if (closed) return;
        final shared = _groups.putIfAbsent(
          '$deviceId:$confirmed',
          () => _CovGroup(this, deviceId, confirmed: confirmed),
        );
        group = shared;
        groupEntry = shared.add(object, propertyId, () {
          // the device refused the property in the shared subscription
          groupEntry = null;
          if (!closed) unawaited(subscribeAlone());
        });
        return;
      }
      await subscribeAlone();
    };

    controller.onCancel = () async {
      closed = true;
      pollingTimer?.cancel();
      renewTimer?.cancel();
      await covSubscription?.cancel();
      _activeMonitors.remove(key);
      if (groupEntry case final entry?) {
        group?.remove(entry);
      }
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

  /// Whether [deviceId] executes SubscribeCOVPropertyMultiple, read once
  /// from its Protocol_Services_Supported.
  Future<bool> _supportsCovMultiple(int deviceId) =>
      _covMultipleSupport.putIfAbsent(deviceId, () async {
        try {
          final services = await client.read(
            deviceId,
            BacnetObject(type: BacnetObjectType.device, instance: deviceId),
            BacnetProperties.protocolServicesSupported,
          );
          return services.contains(
            BacnetServiceSupported.subscribeCovPropertyMultiple,
          );
        } on BacnetTimeoutException {
          // ask again for the next monitor
          unawaited(Future(() => _covMultipleSupport.remove(deviceId)));
          return false;
        } on BacnetException {
          return false;
        }
      });

  void _covMultipleRefused(int deviceId) =>
      _covMultipleSupport[deviceId] = Future.value(false);
}

/// A property in the shared subscription of a [_CovGroup].
final class _CovGroupEntry {
  _CovGroupEntry(this.object, this.property, this.fallBack);

  final BacnetObject object;
  final BacnetPropertyId property;

  /// False once the monitor stopped.
  bool active = true;

  /// Called when the device refuses the property in the shared
  /// subscription: the monitor subscribes to it alone.
  final void Function() fallBack;
}

/// The SubscribeCOVPropertyMultiple subscription of the monitored
/// properties of one device: new properties are subscribed together (one
/// request at a time, the next one with all properties added meanwhile),
/// renewed together and cancelled as their monitors stop.
final class _CovGroup {
  _CovGroup(this.monitor, this.deviceId, {required this.confirmed})
    : processId = monitor.client.allocateProcessId();

  final PropertyMonitor monitor;
  final int deviceId;
  final bool confirmed;
  final int processId;

  /// Subscribed entries.
  final _entries = <_CovGroupEntry>[];

  /// Entries to subscribe.
  final _pending = <_CovGroupEntry>[];

  /// Subscribed entries to cancel.
  final _removed = <_CovGroupEntry>[];
  Timer? _renewTimer;
  var _renewDue = false;
  Future<void>? _running;

  BacnetClient get _client => monitor.client;

  _CovGroupEntry add(
    BacnetObject object,
    BacnetPropertyId property,
    void Function() fallBack,
  ) {
    final entry = _CovGroupEntry(object, property, fallBack);
    _pending.add(entry);
    _schedule();
    return entry;
  }

  void remove(_CovGroupEntry entry) {
    entry.active = false;
    if (_pending.remove(entry)) return;
    if (_entries.remove(entry)) {
      _removed.add(entry);
      _schedule();
    }
    // else in a request on its way: cancelled when it is answered
  }

  void _schedule() {
    _running ??= Future(_run).whenComplete(() {
      _running = null;
      if (_pending.isNotEmpty || _removed.isNotEmpty || _renewDue) {
        _schedule();
      }
    });
  }

  Future<void> _run() async {
    if (_removed.isNotEmpty) {
      final removed = [..._removed];
      _removed.clear();
      await _cancel(removed);
    }
    if (_renewDue) {
      _renewDue = false;
      final accepted = await _subscribe([..._entries]);
      // refused ones fell back to subscriptions of their own
      _entries.removeWhere((entry) => !accepted.contains(entry));
    }
    if (_pending.isNotEmpty) {
      final added = [..._pending];
      _pending.clear();
      for (final entry in await _subscribe(added)) {
        (entry.active ? _entries : _removed).add(entry);
      }
    }
    if (_entries.isEmpty) {
      _renewTimer?.cancel();
      _renewTimer = null;
    } else if (_renewTimer == null) {
      final lifetime = monitor.subscriptionLifetime;
      _renewTimer = Timer(
        Duration(milliseconds: lifetime.inMilliseconds * 3 ~/ 4),
        () {
          _renewTimer = null;
          _renewDue = true;
          _schedule();
        },
      );
    }
  }

  /// Subscribes [entries] in requests that fit the device; returns the
  /// accepted ones and lets the others fall back.
  Future<List<_CovGroupEntry>> _subscribe(List<_CovGroupEntry> entries) async {
    final maxApdu = await _client.deviceMaxApdu(deviceId) ?? 480;
    final accepted = <_CovGroupEntry>[];
    for (final chunk in _chunks(entries, maxApdu)) {
      var remaining = chunk;
      while (remaining.isNotEmpty) {
        try {
          await _client.subscribeCOVPropertyMultiple(
            deviceId,
            _specifications(remaining),
            processId: processId,
            confirmed: confirmed,
            lifetime: monitor.subscriptionLifetime,
          );
          accepted.addAll(remaining);
          break;
        } on BacnetProtocolException catch (e) {
          final failed = e.firstFailedSubscription;
          final refused = failed == null
              ? null
              : remaining.where(
                  (entry) =>
                      entry.object == failed.object &&
                      entry.property == failed.property,
                );
          if (refused == null || refused.isEmpty) {
            _fallBack(remaining, e);
            break;
          }
          // retry without the refused property
          final first = refused.first;
          _fallBack([first], e);
          remaining = [...remaining]..remove(first);
        } on BacnetException catch (e) {
          if (e is BacnetRejectException || e is BacnetAbortException) {
            monitor._covMultipleRefused(deviceId);
          }
          _fallBack(remaining, e);
          break;
        }
      }
    }
    return accepted;
  }

  Future<void> _cancel(List<_CovGroupEntry> entries) async {
    final maxApdu = await _client.deviceMaxApdu(deviceId) ?? 480;
    for (final chunk in _chunks(entries, maxApdu)) {
      try {
        await _client.unsubscribeCOVPropertyMultiple(
          deviceId,
          _specifications(chunk),
          processId: processId,
        );
      } on BacnetException {
        // the subscriptions expire on their own
      }
    }
  }

  void _fallBack(List<_CovGroupEntry> entries, BacnetException error) {
    _client.log(
      BacnetLogLevel.info,
      'SubscribeCOVPropertyMultiple to $deviceId refused '
      '${entries.length} properties, subscribing them alone',
      error,
    );
    for (final entry in entries) {
      if (entry.active) entry.fallBack();
    }
  }

  static List<BacnetCovSubscriptionSpecification> _specifications(
    List<_CovGroupEntry> entries,
  ) {
    final byObject = <BacnetObject, List<BacnetCovReference>>{};
    for (final entry in entries) {
      (byObject[entry.object] ??= []).add(BacnetCovReference(entry.property));
    }
    return [
      for (final MapEntry(key: object, value: references) in byObject.entries)
        BacnetCovSubscriptionSpecification(object, references),
    ];
  }

  /// Splits [entries] into requests that fit in [maxApdu] octets.
  static Iterable<List<_CovGroupEntry>> _chunks(
    List<_CovGroupEntry> entries,
    int maxApdu,
  ) sync* {
    // APDU header and process id, lifetime and the other parameters
    final limit = maxApdu - 24;
    var chunk = <_CovGroupEntry>[];
    for (final entry in entries) {
      final candidate = [...chunk, entry];
      final size = encodeSubscribeCovPropertyMultiple(
        subscriberProcessId: 0,
        specifications: _specifications(candidate),
      ).length;
      if (size > limit && chunk.isNotEmpty) {
        yield chunk;
        chunk = [entry];
      } else {
        chunk = candidate;
      }
    }
    if (chunk.isNotEmpty) yield chunk;
  }
}
