import 'dart:async';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// A widget that monitors and displays a BACnet property value in real-time.
///
/// Supports COV (Change of Value) subscriptions for automatic updates,
/// with a fallback to periodic polling if COV is not available.
class PropertyMonitorWidget extends StatefulWidget {
  const PropertyMonitorWidget({
    required this.deviceId,
    required this.objectType,
    required this.instance,
    required this.propertyId,
    this.propertyName,
    this.refreshInterval = const Duration(seconds: 5),
    this.enableCOV = true,
    super.key,
  });

  /// The device ID to monitor.
  final int deviceId;

  /// The object type.
  final int objectType;

  /// The object instance.
  final int instance;

  /// The property ID to monitor.
  final int propertyId;

  /// Optional human-readable property name.
  final String? propertyName;

  /// How often to refresh the value if COV is not available.
  final Duration refreshInterval;

  /// Whether to attempt COV subscription.
  final bool enableCOV;

  @override
  State<PropertyMonitorWidget> createState() => _PropertyMonitorWidgetState();
}

class _PropertyMonitorWidgetState extends State<PropertyMonitorWidget> {
  dynamic _currentValue;
  DateTime? _lastUpdate;
  bool _isLoading = false;
  String? _errorMessage;
  Timer? _refreshTimer;
  StreamSubscription? _eventSubscription;
  bool _covSubscribed = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _eventSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    final appState = context.read<AppState>();

    // Subscribe to COV if enabled
    if (widget.enableCOV) {
      try {
        await appState.client.subscribeCOV(
          widget.deviceId,
          widget.objectType,
          widget.instance,
          propId: widget.propertyId,
        );
        _covSubscribed = true;

        // Listen for COV notifications
        _eventSubscription = appState.client.events.listen((event) {
          if (event is COVNotificationResponse) {
            if (event.deviceId == widget.deviceId &&
                event.objectType == widget.objectType &&
                event.instance == widget.instance) {
              if (mounted) {
                setState(() {
                  _lastUpdate = DateTime.now();
                  _errorMessage = null;
                });
                // Trigger a manual read to get the latest value
                _readValue();
              }
            }
          }
        });
      } on Exception catch (e) {
        // COV subscription failed, fall back to polling
        if (mounted) {
          setState(() {
            _errorMessage = 'COV subscription failed: $e';
          });
        }
      }
    }

    // Initial read
    await _readValue();

    // Start periodic refresh as fallback
    _refreshTimer = Timer.periodic(widget.refreshInterval, (_) {
      _readValue();
    });
  }

  Future<void> _readValue() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final appState = context.read<AppState>();
      final value = await appState.client.readProperty(
        widget.deviceId,
        widget.objectType,
        widget.instance,
        widget.propertyId,
      );

      if (mounted) {
        setState(() {
          _currentValue = value;
          _lastUpdate = DateTime.now();
          _isLoading = false;
        });
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Read failed: $e';
          _isLoading = false;
        });
      }
    }
  }

  String _formatValue(dynamic value) {
    if (value == null) return 'null';
    if (value is double) return value.toStringAsFixed(2);
    if (value is Map) {
      // Handle object identifiers
      if (value.containsKey('type') && value.containsKey('instance')) {
        return '${value['type']}:${value['instance']}';
      }
      return value.toString();
    }
    return value.toString();
  }

  String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) return 'Never';
    final now = DateTime.now();
    final diff = now.difference(timestamp);

    if (diff.inSeconds < 60) {
      return '${diff.inSeconds}s ago';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else {
      return '${diff.inHours}h ago';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.propertyName ?? 'Property ${widget.propertyId}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Object ${widget.objectType}:${widget.instance}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_covSubscribed)
                      Tooltip(
                        message: 'COV Subscribed',
                        child: Icon(
                          Icons.notifications_active,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    const SizedBox(width: 8),
                    if (_isLoading)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        onPressed: _readValue,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Refresh',
                      ),
                  ],
                ),
              ],
            ),
            const Divider(),
            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Current Value',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatValue(_currentValue),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Last updated: ${_formatTimestamp(_lastUpdate)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
