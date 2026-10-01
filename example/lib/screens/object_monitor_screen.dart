import 'dart:async';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../format_value.dart';

/// Screen for monitoring a BACnet object's properties with COV subscription.
class ObjectMonitorScreen extends StatefulWidget {
  const ObjectMonitorScreen({
    required this.deviceId,
    required this.object,
    super.key,
  });

  final int deviceId;
  final BacnetObject object;

  @override
  State<ObjectMonitorScreen> createState() => _ObjectMonitorScreenState();
}

class _ObjectMonitorScreenState extends State<ObjectMonitorScreen> {
  String? _objectName;
  BacnetValue? _presentValue;
  String? _units;
  String? _errorMessage;
  bool _isLoading = true;
  bool _isCovActive = false;

  StreamSubscription<PropertyUpdate>? _covSubscription;
  PropertyMonitor? _propertyMonitor;

  final List<PropertyValueUpdate> _valueHistory = [];

  @override
  void initState() {
    super.initState();
    _loadObjectInfo();
  }

  @override
  void dispose() {
    _covSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadObjectInfo() async {
    final client = context.read<AppState>().client;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Use RPM to read multiple properties at once
      final results = await client.readMultiple(widget.deviceId, [
        BacnetReadAccessSpecification(
          objectIdentifier: widget.object,
          properties: const [
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.objectName,
            ),
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.presentValue,
            ),
            BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.units),
            BacnetPropertyReference(
              propertyIdentifier: BacnetPropertyId.description,
            ),
          ],
        ),
      ]);

      final props = results[widget.object];

      if (props != null) {
        // Present_Value has no fixed datatype; the others are typed
        final presentValue = props.valueOf(BacnetPropertyId.presentValue);
        setState(() {
          _objectName = props.get(BacnetProperties.objectName);
          _presentValue = presentValue;
          _units = props.get(BacnetProperties.units)?.label;
          _isLoading = false;
        });

        // Add to history
        if (presentValue != null) {
          _valueHistory.add(
            PropertyValueUpdate(
              deviceId: widget.deviceId,
              objectIdentifier: widget.object,
              propertyIdentifier: BacnetPropertyId.presentValue,
              value: presentValue,
              timestamp: DateTime.now(),
              source: UpdateSource.manual,
            ),
          );
        }
      } else {
        setState(() {
          _errorMessage = 'No data returned';
          _isLoading = false;
        });
      }
    } on Exception catch (e) {
      setState(() {
        _errorMessage = 'Failed to load: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleCovSubscription() async {
    if (_isCovActive) {
      // Unsubscribe
      await _covSubscription?.cancel();
      _covSubscription = null;
      setState(() {
        _isCovActive = false;
      });
      return;
    }

    // Subscribe to COV
    final client = context.read<AppState>().client;
    _propertyMonitor = PropertyMonitor(client);

    final stream = _propertyMonitor!.monitor(
      deviceId: widget.deviceId,
      object: widget.object,
      propertyId: BacnetPropertyId.presentValue,
      pollingInterval: const Duration(seconds: 3),
      preferPolling: true, // Use polling since COV might not be supported
    );

    _covSubscription = stream.listen(
      (update) {
        switch (update) {
          case PropertyValueUpdate(:final value):
            setState(() {
              _presentValue = value;
              _valueHistory.add(update);
              // Keep only last 20 values
              if (_valueHistory.length > 20) {
                _valueHistory.removeAt(0);
              }
            });
          case PropertyErrorUpdate(:final error):
            debugPrint('Read failed: $error');
        }
      },
      onError: (Object e) {
        debugPrint('COV Error: $e');
      },
    );

    setState(() {
      _isCovActive = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Value monitoring started (polling every 3s)'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _objectName ??
              'Object ${widget.object.type}:${widget.object.instance}',
        ),
        actions: [
          IconButton(
            icon: Icon(_isCovActive ? Icons.stop : Icons.play_arrow),
            onPressed: _toggleCovSubscription,
            tooltip: _isCovActive ? 'Stop Monitoring' : 'Start Monitoring',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadObjectInfo,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_errorMessage!),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadObjectInfo,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildValueCard(),
        const SizedBox(height: 16),
        _buildInfoCard(),
        const SizedBox(height: 16),
        _buildHistoryCard(),
      ],
    );
  }

  Widget _buildValueCard() {
    return Card(
      color: _isCovActive ? Colors.green.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              'Present Value',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              switch (_presentValue) {
                final value? => formatValue(value),
                null => 'N/A',
              },
              style: Theme.of(context).textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).primaryColor,
              ),
            ),
            if (_units != null) ...[
              const SizedBox(height: 4),
              Text(_units!, style: Theme.of(context).textTheme.titleSmall),
            ],
            if (_isCovActive) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('Live', style: TextStyle(color: Colors.green)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Object Info', style: Theme.of(context).textTheme.titleLarge),
            const Divider(),
            _buildRow('Object Name', _objectName ?? 'Unknown'),
            _buildRow('Type', widget.object.type.label),
            _buildRow('Instance', widget.object.instance.toString()),
            _buildRow('Device ID', widget.deviceId.toString()),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Value History (${_valueHistory.length})',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Divider(),
            if (_valueHistory.isEmpty)
              const Text('No history yet')
            else
              ..._valueHistory.reversed.take(10).map((update) {
                final time =
                    '${update.timestamp.hour.toString().padLeft(2, '0')}:'
                    '${update.timestamp.minute.toString().padLeft(2, '0')}:'
                    '${update.timestamp.second.toString().padLeft(2, '0')}';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        update.source == UpdateSource.cov
                            ? Icons.notifications
                            : Icons.refresh,
                        size: 16,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        time,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          formatValue(update.value),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
