import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'device_detail_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final BacnetClient _client;

  final List<String> _logs = [];
  final Set<int> _devices = {};
  final TextEditingController _ipController = TextEditingController(
    text: '192.168.100.134',
  );
  final TextEditingController _interfaceController = TextEditingController(
    text: '192.168.100.134',
  );
  final TextEditingController _portController = TextEditingController(
    text:
        '47809', // Default to 47809 to avoid conflict with Simulator (at 47808)
  );

  @override
  void initState() {
    super.initState();
    _client = BacnetClient(
      logger: CallbackLogger((level, message, error, stackTrace) {
        String msg = '[$level] $message';
        if (error != null) msg += '\nError: $error';
        _log(msg);
      }),
    );

    // Auto-start for testing

    Future.delayed(const Duration(seconds: 1), () {
      _initBacnet();
      Future.delayed(const Duration(seconds: 1), () {
        _client.registerForeignDevice(_ipController.text);
        _log('Auto-Registered FDR to ${_ipController.text}');

        // Manual Binding Force (Device 2949195 -> 192.168.100.134:47808)
        _client.addDeviceBinding(2949195, '192.168.100.134', port: 47808);
        _log('Added Manual Binding for 2949195');

        _addManualDevice();
        _client.sendWhoIs().then((_) => _log('Sent Who-Is (Auto)'));
        Future.delayed(const Duration(seconds: 2), () {
          _client
              .scanDevice(2949195)
              .then((l) => _log('Auto-Scan: ${l.length} objects'));
        });
      });
    });
  }

  void _initBacnet() async {
    final port = int.tryParse(_portController.text) ?? 47809;
    await _client.start(interface: _interfaceController.text, port: port);
    _log('BACnet Stack Started on ${_interfaceController.text}:$port');

    _client.events.listen((event) {
      if (event is IAmResponse) {
        final devId = event.deviceId;
        if (devId != -1) {
          if (!_devices.contains(devId)) {
            setState(() => _devices.add(devId));
            _log('Discovered Device $devId');
          }
        } else {
          _log('Received I-Am but could not decode Device ID');
        }
      } else if (event is Map) {
        // Fallback for any legacy maps
        final type = event['type'] ?? event['event'];
        if (type == 'I_AM') {
          // Legacy handling
        }
      }
    });
  }

  void _log(String msg) {
    void update() {
      if (!mounted) return;
      setState(() {
        _logs.insert(
          0,
          '${DateTime.now().toIso8601String().split('T')[1].split('.').first}: $msg',
        );
      });
    }

    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => update());
    } else {
      update();
    }
  }

  void _addManualDevice() {
    // Add emulator manually
    setState(() => _devices.add(2949195));
    _log('Manually added Emulator 2949195');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Controls
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _interfaceController,
                          decoration: const InputDecoration(
                            labelText: 'Local Interface IP',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: _portController,
                          decoration: const InputDecoration(labelText: 'Port'),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      ElevatedButton(
                        onPressed: _initBacnet,
                        child: const Text('Start'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _ipController,
                          decoration: const InputDecoration(
                            labelText: 'Emulator / BBMD IP',
                          ),
                        ),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                        ),
                        onPressed: () {
                          _client.registerForeignDevice(_ipController.text);
                          _log('Registered FDR to ${_ipController.text}');
                          // Also send WhoIs to that specific unicast address directly?
                          // The plugin sendWhoIs broadcasts.
                          // But we can manually wait or just add device.
                          _addManualDevice();
                        },
                        child: const Text('Connect to Emulator'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          _client.sendWhoIs();
                          _log('Sent Who-Is Broadcast');
                        },
                        child: const Text('Who-Is'),
                      ),
                      ElevatedButton(
                        onPressed: _addManualDevice,
                        child: const Text('Add 2949195'),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          setState(() => _devices.clear());
                          _log('Cleared List');
                        },
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),

        // Device List
        Expanded(
          child: ListView.builder(
            itemCount: _devices.length,
            itemBuilder: (context, index) {
              final devId = _devices.elementAt(index);
              return ListTile(
                leading: const Icon(Icons.router, color: Colors.green),
                title: Text('Device $devId'),
                subtitle: const Text('BACnet/IP Device'),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DeviceDetailScreen(deviceId: devId),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class CallbackLogger implements BacnetLogger {
  final void Function(
    BacnetLogLevel level,
    String message,
    Object? error,
    StackTrace? stackTrace,
  )
  callback;

  const CallbackLogger(this.callback);

  @override
  void log(
    BacnetLogLevel level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    callback(level, message, error, stackTrace);
  }
}
