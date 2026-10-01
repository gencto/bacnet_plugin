import 'dart:async';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../widgets/empty_state_widget.dart';

/// Alarms of a device: subscribes to its Notification Classes, lists the
/// objects in alarm (GetEventInformation) and acknowledges them.
class AlarmsScreen extends StatefulWidget {
  const AlarmsScreen({
    required this.deviceId,
    required this.notificationClasses,
    super.key,
  });

  final int deviceId;

  /// Instances of the Notification Class objects of the device.
  final List<int> notificationClasses;

  @override
  State<AlarmsScreen> createState() => _AlarmsScreenState();
}

class _AlarmsScreenState extends State<AlarmsScreen> {
  static const _source = 'BACnet Demo';

  late final BacnetClient _client = context.read<AppState>().client;
  final _subscriptions = <AlarmSubscription>[];
  final _listeners = <StreamSubscription<EventNotificationEvent>>[];
  final _recent = <EventNotificationEvent>[];
  List<BacnetEventSummary> _summaries = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_subscribe());
  }

  @override
  void dispose() {
    for (final listener in _listeners) {
      unawaited(listener.cancel());
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    super.dispose();
  }

  Future<void> _subscribe() async {
    final failures = <String>[];
    for (final instance in widget.notificationClasses) {
      try {
        final subscription = await _client.subscribeAlarms(
          widget.deviceId,
          notificationClass: instance,
        );
        _subscriptions.add(subscription);
        _listeners.add(subscription.notifications.listen(_onNotification));
      } on BacnetException catch (e) {
        failures.add('Notification Class $instance: ${e.message}');
      }
    }
    if (failures.isNotEmpty) _error = failures.join('\n');
    await _refresh();
  }

  void _onNotification(EventNotificationEvent event) {
    setState(() {
      _recent.insert(0, event);
      if (_recent.length > 50) _recent.removeLast();
    });
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final summaries = await _client.getEventInformation(widget.deviceId);
      if (!mounted) return;
      setState(() {
        _summaries = summaries;
        _loading = false;
      });
    } on BacnetException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'GetEventInformation failed: ${e.message}';
        _loading = false;
      });
    }
  }

  /// Acknowledges every transition of [summary] that waits for it.
  Future<void> _acknowledge(BacnetEventSummary summary) async {
    try {
      for (final transition in summary.unacknowledgedTransitions) {
        final timeStamp = summary.timeStampOf(transition);
        if (timeStamp == null) continue;
        await _client.acknowledgeAlarm(
          widget.deviceId,
          summary.object,
          summary.stateOf(transition),
          timeStamp,
          source: _source,
        );
      }
      await _refresh();
    } on BacnetException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Acknowledge failed: ${e.message}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Alarms of device ${widget.deviceId}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (widget.notificationClasses.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.notifications_off_outlined,
        title: 'No Notification Class',
        description: 'This device does not report alarms',
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_error case final error?)
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(error),
            ),
          ),
        Text(
          'Active (${_summaries.length})',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        if (_summaries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('No objects in alarm'),
          ),
        for (final summary in _summaries)
          Card(
            child: ListTile(
              leading: Icon(
                summary.eventState == BacnetEventState.normal
                    ? Icons.check_circle_outline
                    : Icons.warning_amber,
                color: summary.eventState == BacnetEventState.normal
                    ? Colors.green
                    : Colors.orange,
              ),
              title: Text(
                '${summary.object.type.label} ${summary.object.instance}',
              ),
              subtitle: Text(
                '${summary.eventState.label} · ${summary.notifyType.label}',
              ),
              trailing: summary.isUnacknowledged
                  ? FilledButton(
                      onPressed: () => _acknowledge(summary),
                      child: const Text('Acknowledge'),
                    )
                  : const Text('acknowledged'),
            ),
          ),
        const SizedBox(height: 24),
        Text('Notifications', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        if (_recent.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('Waiting for notifications...'),
          ),
        for (final event in _recent)
          ListTile(
            dense: true,
            leading: Icon(
              event.isAckNotification
                  ? Icons.done_all
                  : Icons.notifications_active_outlined,
            ),
            title: Text(
              '${event.object.type.label} ${event.object.instance}: '
              '${event.fromState?.label ?? ''} → ${event.toState.label}',
            ),
            subtitle: Text(
              [
                event.notifyType.label,
                if (event.messageText case final text?) text,
                if (event.eventValues case final values?) _describe(values),
              ].join(' · '),
            ),
          ),
      ],
    );
  }

  static String _describe(BacnetEventValues values) => switch (values) {
    BacnetOutOfRangeValues(:final exceedingValue, :final exceededLimit) =>
      '${exceedingValue.toStringAsFixed(1)} beyond '
          '${exceededLimit.toStringAsFixed(1)}',
    BacnetChangeOfStateValues(:final newState) =>
      'state ${newState.asBinaryPV?.label ?? newState.value}',
    BacnetChangeOfReliabilityValues(:final reliability) => reliability.label,
    _ => values.eventType.label,
  };
}
