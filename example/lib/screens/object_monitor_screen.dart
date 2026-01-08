import 'dart:async';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

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
  dynamic _presentValue;
  String? _units;
  String? _errorMessage;
  bool _isLoading = true;
  bool _isCovActive = false;

  StreamSubscription<PropertyUpdate>? _covSubscription;
  PropertyMonitor? _propertyMonitor;

  final List<PropertyUpdate> _valueHistory = [];

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

      final key = '${widget.object.type}:${widget.object.instance}';
      final props = results[key];

      if (props != null) {
        setState(() {
          _objectName = props[BacnetPropertyId.objectName] as String?;
          _presentValue = props[BacnetPropertyId.presentValue];
          _units = _getUnitsString(props[BacnetPropertyId.units]);
          _isLoading = false;
        });

        // Add to history
        _valueHistory.add(
          PropertyUpdate(
            deviceId: widget.deviceId,
            objectIdentifier: widget.object,
            propertyIdentifier: BacnetPropertyId.presentValue,
            value: _presentValue,
            timestamp: DateTime.now(),
            source: UpdateSource.manual,
          ),
        );
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
        setState(() {
          _presentValue = update.value;
          _valueHistory.add(update);
          // Keep only last 20 values
          if (_valueHistory.length > 20) {
            _valueHistory.removeAt(0);
          }
        });
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

  String? _getUnitsString(dynamic units) {
    if (units == null) return null;
    if (units is int) {
      // Common BACnet units
      const unitNames = {62: '°C', 64: '°F', 95: '%', 98: 'Pa', 0: 'no-units'};
      return unitNames[units] ?? 'Units: $units';
    }
    return units.toString();
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
              _presentValue?.toString() ?? 'N/A',
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
            _buildRow('Type', _getTypeName(widget.object.type)),
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
                          '${update.value}',
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

  String _getTypeName(int type) {
    const names = {
      0: 'Analog Input',
      1: 'Analog Output',
      2: 'Analog Value',
      3: 'Binary Input',
      4: 'Binary Output',
      5: 'Binary Value',
      8: 'Device',
    };
    return names[type] ?? 'Type $type';
  }
}
