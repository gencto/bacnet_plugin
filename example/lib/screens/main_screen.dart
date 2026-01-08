import 'package:flutter/material.dart';

import '../models/app_mode.dart';
import 'dashboard_screen.dart';
import 'server/server_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  AppMode _currentMode = AppMode.client;

  void _switchMode(AppMode newMode) {
    if (_currentMode == newMode) return;

    // Show confirmation dialog
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Switch Mode'),
        content: Text(
          'Switching to ${newMode.displayName} mode will stop the current ${_currentMode.displayName} instance.\n\nContinue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() => _currentMode = newMode);
            },
            child: const Text('Switch'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(
              _currentMode == AppMode.client ? Icons.wifi_find : Icons.router,
            ),
            const SizedBox(width: 8),
            Text('BACnet ${_currentMode.displayName}'),
          ],
        ),
        actions: [
          // Mode Toggle
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: SegmentedButton<AppMode>(
              segments: const [
                ButtonSegment(
                  value: AppMode.client,
                  icon: Icon(Icons.wifi_find, size: 16),
                  label: Text('Client'),
                ),
                ButtonSegment(
                  value: AppMode.server,
                  icon: Icon(Icons.router, size: 16),
                  label: Text('Server'),
                ),
              ],
              selected: {_currentMode},
              onSelectionChanged: (Set<AppMode> selection) {
                _switchMode(selection.first);
              },
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return Colors.teal;
                  }
                  return null;
                }),
              ),
            ),
          ),
        ],
      ),
      body: _currentMode == AppMode.client
          ? const DashboardScreen()
          : const ServerScreen(),
    );
  }
}
