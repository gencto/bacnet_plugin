import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../format_value.dart';

/// Explores every property of a BACnet object: reads them with
/// ReadPropertyMultiple (property `all`) and writes the present value.
class ObjectExplorerScreen extends StatefulWidget {
  const ObjectExplorerScreen({
    required this.deviceId,
    required this.object,
    this.objectName,
    super.key,
  });

  final int deviceId;
  final BacnetObject object;
  final String? objectName;

  @override
  State<ObjectExplorerScreen> createState() => _ObjectExplorerScreenState();
}

class _ObjectExplorerScreenState extends State<ObjectExplorerScreen> {
  Map<BacnetPropertyId, BacnetPropertyResult>? _properties;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final client = context.read<AppState>().client;
      final result = await client.readMultiple(widget.deviceId, [
        BacnetReadAccessSpecification(
          objectIdentifier: widget.object,
          properties: const [
            BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.all),
          ],
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _properties = result[widget.object] ?? const {};
        _isLoading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to read properties: $e';
        _isLoading = false;
      });
    }
  }

  /// Parses the text into a BACnet value for a present-value write, matching
  /// the datatype of the current present value [like] when known so an Analog
  /// value stays a REAL and a Binary value an enumeration.
  BacnetValue _parse(String text, BacnetValue? like) {
    final trimmed = text.trim();
    final asInt = int.tryParse(trimmed);
    final asDouble = double.tryParse(trimmed);
    switch (like) {
      case BacnetReal() || BacnetDouble():
        if (asDouble != null) return BacnetReal(asDouble);
      case BacnetUnsigned():
        if (asInt != null && asInt >= 0) return BacnetUnsigned(asInt);
      case BacnetSigned():
        if (asInt != null) return BacnetSigned(asInt);
      case BacnetEnumerated():
        if (asInt != null) return BacnetEnumerated(asInt);
      case BacnetBoolean():
        return BacnetBoolean(trimmed == '1' || trimmed.toLowerCase() == 'true');
      case BacnetCharacterString():
        return BacnetCharacterString(trimmed);
      default:
        break;
    }
    // no typed present value to match: infer from the text
    if (trimmed.toLowerCase() == 'true') return const BacnetBoolean(true);
    if (trimmed.toLowerCase() == 'false') return const BacnetBoolean(false);
    if (asInt != null) {
      return asInt >= 0 ? BacnetUnsigned(asInt) : BacnetSigned(asInt);
    }
    if (asDouble != null) return BacnetReal(asDouble);
    return BacnetCharacterString(trimmed);
  }

  Future<void> _writePresentValue() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Write present value'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Value',
            helperText: 'a number, true/false, or text',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Write'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final current = _properties?[BacnetPropertyId.presentValue];
    try {
      await context.read<AppState>().client.writeProperty(
        widget.deviceId,
        widget.object.type,
        widget.object.instance,
        BacnetPropertyId.presentValue,
        _parse(text, current is BacnetValue ? current : null),
        priority: 8,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Present value written')),
      );
      await _load();
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Write failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.objectName ??
              '${widget.object.type.label} ${widget.object.instance}',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: _isLoading ? null : _writePresentValue,
            tooltip: 'Write present value',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _load,
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
      return Center(child: Text(_errorMessage!));
    }
    final properties = _properties ?? const {};
    if (properties.isEmpty) {
      return const Center(child: Text('No properties returned'));
    }
    final ids = properties.keys.toList()..sort((a, b) => a.value - b.value);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: ids.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final id = ids[index];
          final result = properties[id]!;
          return ListTile(
            dense: true,
            title: Text(id.label),
            subtitle: switch (result) {
              final BacnetValue value => Text(formatValue(value)),
              BacnetError(:final errorClass, :final errorCode) => Text(
                'error: ${errorClass.label} / ${errorCode.label}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            },
          );
        },
      ),
    );
  }
}
