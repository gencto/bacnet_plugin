import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../models/server_object.dart';
import '../../widgets/log_console.dart';

class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key});

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  BacnetServer? _server;
  bool _isRunning = false;
  final List<ServerObject> _objects = [];
  final List<String> _logs = [];

  final TextEditingController _deviceIdController = TextEditingController(
    text: '1234',
  );
  final TextEditingController _deviceNameController = TextEditingController(
    text: 'FlutterServer',
  );
  final TextEditingController _portController = TextEditingController(
    text: '47808',
  );

  @override
  void dispose() {
    _server?.dispose();
    _deviceIdController.dispose();
    _deviceNameController.dispose();
    _portController.dispose();
    super.dispose();
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

  Future<void> _startServer() async {
    try {
      final deviceId = int.parse(_deviceIdController.text);
      final deviceName = _deviceNameController.text;
      final port = int.parse(_portController.text);

      _server = BacnetServer(
        logger: CallbackLogger((level, message, error, stackTrace) {
          String msg = '[$level] $message';
          if (error != null) msg += '\nError: $error';
          _log(msg);
        }),
      );

      await _server!.start(port: port);
      _log('Server started on port $port');

      await _server!.init(deviceId, deviceName);
      _log('Device initialized: $deviceId ($deviceName)');

      // Listen to write events
      _server!.writeEvents.listen((event) {
        _log(
          'Write received: ${event.objectType}:${event.instance} '
          'Property ${event.propertyId} = ${event.value}',
        );
      });

      setState(() => _isRunning = true);
    } catch (e, st) {
      _log('Failed to start server: $e');
      _log('Stack: $st');
    }
  }

  Future<void> _stopServer() async {
    _server?.dispose();
    _server = null;
    setState(() {
      _isRunning = false;
      _objects.clear();
    });
    _log('Server stopped');
  }

  Future<void> _showAddObjectDialog() async {
    int? selectedType = 2; // Default to AV
    int instance = 0;

    final result = await showDialog<Map<String, int>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add Object'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: selectedType,
                decoration: const InputDecoration(labelText: 'Object Type'),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('AI - Analog Input')),
                  DropdownMenuItem(value: 1, child: Text('AO - Analog Output')),
                  DropdownMenuItem(value: 2, child: Text('AV - Analog Value')),
                  DropdownMenuItem(value: 3, child: Text('BI - Binary Input')),
                  DropdownMenuItem(value: 4, child: Text('BV - Binary Value')),
                  DropdownMenuItem(value: 5, child: Text('BO - Binary Output')),
                ],
                onChanged: (value) => setState(() => selectedType = value),
              ),
              const SizedBox(height: 16),
              TextFormField(
                initialValue: instance.toString(),
                decoration: const InputDecoration(labelText: 'Instance'),
                keyboardType: TextInputType.number,
                onChanged: (value) => instance = int.tryParse(value) ?? 0,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, {
                'type': selectedType!,
                'instance': instance,
              }),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (result != null && _server != null) {
      try {
        await _server!.addObject(result['type']!, result['instance']!);
        setState(() {
          _objects.add(
            ServerObject(
              objectType: result['type']!,
              instance: result['instance']!,
              typeName: ServerObject.getTypeName(result['type']!),
            ),
          );
        });
        _log(
          'Added ${ServerObject.getTypeName(result['type']!)}:${result['instance']}',
        );
      } catch (e) {
        _log('Failed to add object: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Server Controls
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isRunning ? Icons.check_circle : Icons.circle_outlined,
                        color: _isRunning ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isRunning ? 'Server Running' : 'Server Stopped',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (!_isRunning) ...[
                    TextField(
                      controller: _deviceIdController,
                      decoration: const InputDecoration(
                        labelText: 'Device ID',
                        isDense: true,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _deviceNameController,
                      decoration: const InputDecoration(
                        labelText: 'Device Name',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _portController,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        isDense: true,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (!_isRunning)
                        ElevatedButton.icon(
                          onPressed: _startServer,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Start Server'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                          ),
                        )
                      else
                        ElevatedButton.icon(
                          onPressed: _stopServer,
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop Server'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),

        // Objects List
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            children: [
              Text(
                'Objects (${_objects.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              if (_isRunning)
                IconButton(
                  onPressed: _showAddObjectDialog,
                  icon: const Icon(Icons.add_circle),
                  color: Colors.teal,
                  tooltip: 'Add Object',
                ),
            ],
          ),
        ),

        Expanded(
          child: _objects.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.inventory_2_outlined,
                        size: 64,
                        color: Colors.grey[600],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _isRunning
                            ? 'No objects created yet\nTap + to add'
                            : 'Start server to create objects',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _objects.length,
                  itemBuilder: (context, index) {
                    final obj = _objects[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.teal,
                        child: Text(obj.typeName),
                      ),
                      title: Text(obj.displayName),
                      subtitle: Text(
                        'Type ${obj.objectType}, Instance ${obj.instance}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () {
                          setState(() => _objects.removeAt(index));
                          _log('Removed ${obj.displayName}');
                        },
                      ),
                    );
                  },
                ),
        ),

        // Console
        LogConsole(logs: _logs),
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
