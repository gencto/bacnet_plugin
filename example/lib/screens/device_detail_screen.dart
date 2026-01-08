import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../widgets/empty_state_widget.dart';

/// Screen displaying details and objects for a specific BACnet device.
class DeviceDetailScreen extends StatefulWidget {
  const DeviceDetailScreen({required this.deviceId, super.key});

  final int deviceId;

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  DiscoveredDevice? _device;
  List<BacnetObject>? _objects;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadDeviceData();
  }

  Future<void> _loadDeviceData() async {
    final appState = context.read<AppState>();

    // Find device in discovered list
    try {
      _device = appState.devices.firstWhere(
        (d) => d.deviceId == widget.deviceId,
      );
    } on StateError {
      setState(() {
        _errorMessage = 'Device not found in discovered devices';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Scan device objects
      _objects = await appState.client.scanDevice(widget.deviceId);

      setState(() {
        _isLoading = false;
      });
    } on Exception catch (e) {
      setState(() {
        _errorMessage = 'Failed to load device objects: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_device?.deviceName ?? 'Device ${widget.deviceId}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadDeviceData,
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
      return EmptyStateWidget(
        icon: Icons.error_outline,
        title: 'Error',
        description: _errorMessage!,
        actionLabel: 'Retry',
        onAction: _loadDeviceData,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildDeviceInfo(),
        const SizedBox(height: 24),
        _buildObjectsList(),
      ],
    );
  }

  Widget _buildDeviceInfo() {
    if (_device == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Device Information',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Divider(),
            _buildInfoRow('Device ID', _device!.deviceId.toString()),
            if (_device!.vendorName != null)
              _buildInfoRow('Vendor', _device!.vendorName!),
            if (_device!.modelName != null)
              _buildInfoRow('Model', _device!.modelName!),
            if (_device!.firmwareRevision != null)
              _buildInfoRow('Firmware', _device!.firmwareRevision!),
            if (_device!.applicationSoftwareVersion != null)
              _buildInfoRow('Software', _device!.applicationSoftwareVersion!),
            if (_device!.description != null)
              _buildInfoRow('Description', _device!.description!),
            if (_device!.location != null)
              _buildInfoRow('Location', _device!.location!),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildObjectsList() {
    if (_objects == null || _objects!.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.inventory_2_outlined,
        title: 'No Objects',
        description: 'This device has no objects or they could not be loaded',
      );
    }

    // Group objects by type
    final groupedObjects = <int, List<BacnetObject>>{};
    for (final obj in _objects!) {
      groupedObjects.putIfAbsent(obj.type, () => []).add(obj);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Objects (${_objects!.length})',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        ...groupedObjects.entries.map((entry) {
          final typeName = _getObjectTypeName(entry.key);
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ExpansionTile(
              title: Text('$typeName (${entry.value.length})'),
              children: entry.value.map((obj) {
                return ListTile(
                  dense: true,
                  title: Text('Instance ${obj.instance}'),
                  subtitle: Text('Type: ${obj.type}'),
                  trailing: const Icon(Icons.chevron_right, size: 16),
                  onTap: () {
                    // TODO: Navigate to object detail or show property monitor
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Object ${obj.type}:${obj.instance}'),
                      ),
                    );
                  },
                );
              }).toList(),
            ),
          );
        }),
      ],
    );
  }

  String _getObjectTypeName(int type) {
    // Map common BACnet object types to readable names
    const typeNames = {
      0: 'Analog Input',
      1: 'Analog Output',
      2: 'Analog Value',
      3: 'Binary Input',
      4: 'Binary Output',
      5: 'Binary Value',
      8: 'Device',
      13: 'Multi-state Input',
      14: 'Multi-state Output',
      19: 'Multi-state Value',
      20: 'Trend Log',
    };
    return typeNames[type] ?? 'Type $type';
  }
}
