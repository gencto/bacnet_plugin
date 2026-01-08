import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../widgets/empty_state_widget.dart';

/// Main screen displaying discovered BACnet devices.
class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  @override
  void initState() {
    super.initState();
    // Start client on first launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = context.read<AppState>();
      if (!appState.isStarted) {
        _startClient();
      }
    });
  }

  Future<void> _startClient() async {
    final appState = context.read<AppState>();
    try {
      // Specify interface for correct network binding
      await appState.startClient(interface: '192.168.100.134');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('BACnet client started'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start client: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _discoverDevices() async {
    final appState = context.read<AppState>();
    await appState.discoverDevices();

    if (mounted && appState.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(appState.errorMessage!),
          backgroundColor: Colors.red,
          action: SnackBarAction(
            label: 'Dismiss',
            onPressed: () => appState.clearError(),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BACnet Devices'),
        actions: [
          Consumer<AppState>(
            builder: (context, appState, _) {
              if (!appState.isStarted) {
                return IconButton(
                  icon: const Icon(Icons.power_settings_new),
                  onPressed: _startClient,
                  tooltip: 'Start Client',
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
      body: Consumer<AppState>(
        builder: (context, appState, _) {
          if (!appState.isStarted) {
            return EmptyStateWidget(
              icon: Icons.power_off,
              title: 'Client Not Started',
              description: 'Tap the power button to start the BACnet client',
              actionLabel: 'Start Client',
              onAction: _startClient,
            );
          }

          if (appState.isScanning) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Discovering devices...'),
                ],
              ),
            );
          }

          if (appState.devices.isEmpty) {
            return EmptyStateWidget(
              icon: Icons.devices,
              title: 'No Devices Found',
              description:
                  'Pull down to discover BACnet devices on your network',
              actionLabel: 'Discover Now',
              onAction: _discoverDevices,
            );
          }

          return RefreshIndicator(
            onRefresh: _discoverDevices,
            child: ListView.builder(
              itemCount: appState.devices.length,
              padding: const EdgeInsets.all(8),
              itemBuilder: (context, index) {
                final device = appState.devices[index];
                return Card(
                  margin: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 8,
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                      child: Icon(
                        Icons.router,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    title: Text(
                      device.deviceName ?? 'Device ${device.deviceId}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ID: ${device.deviceId}'),
                        if (device.vendorName != null)
                          Text('Vendor: ${device.vendorName}'),
                        if (device.modelName != null)
                          Text('Model: ${device.modelName}'),
                      ],
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      context.go('/device/${device.deviceId}');
                    },
                  ),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: Consumer<AppState>(
        builder: (context, appState, _) {
          if (!appState.isStarted || appState.isScanning) {
            return const SizedBox.shrink();
          }
          return FloatingActionButton(
            onPressed: _discoverDevices,
            tooltip: 'Discover Devices',
            child: const Icon(Icons.refresh),
          );
        },
      ),
    );
  }
}
