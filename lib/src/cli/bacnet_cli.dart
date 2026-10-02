// The `bacnet` command line tool (bin/bacnet.dart): discovers devices,
// reads, writes, watches and describes them with the public API.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../client/bacnet_client.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/bacnet_config.dart';
import '../core/exceptions.dart';
import '../core/types.dart';
import '../models/bacnet_value.dart';
import '../models/epics_format.dart';
import '../models/property_update.dart';
import '../utilities/device_description.dart';
import '../utilities/device_scanner.dart';
import '../utilities/network_discovery.dart';
import '../utilities/property_monitor.dart';

const _usage = '''
Usage: bacnet [options] <command> [arguments]

Commands:
  discover [--wait <s>]                      Who-Is, lists the devices
  read <device> <object> <property>          reads a property
      [--index <n>]
  write <device> <object> <property> <value> writes a property
      [--priority <1..16>] [--index <n>]
  objects <device>                           lists the objects with names
  describe <device> [--output <file>]        reads all properties (EPICS,
                                             or JSON with --json)
  watch <device> <object> [<property>]       prints changes (COV or polling)
      [--seconds <s>]
  routers [--wait <s>]                       lists the routers

Objects are written as type:instance (analog-input:1, ai:1, 0:1),
properties by name or number (present-value, 85). Values: numbers,
true/false, active/inactive, null, text, or typed as real:21.5,
unsigned:3, signed:-1, enum:1, double:1.5, string:abc.

Options:
  -i, --interface <name|ip>  network interface (default: the first one)
  -p, --port <n>             local UDP port (default 47808)
  -a, --address <ip[:port]>  address of the device (instead of Who-Is)
  --bbmd <ip[:port]>         register as foreign device with this BBMD
  --timeout <s>              request timeout (default 10)
  --json                     JSON output
  -h, --help                 this help
''';

const _objectAbbreviations = {
  'ai': BacnetObjectType.analogInput,
  'ao': BacnetObjectType.analogOutput,
  'av': BacnetObjectType.analogValue,
  'bi': BacnetObjectType.binaryInput,
  'bo': BacnetObjectType.binaryOutput,
  'bv': BacnetObjectType.binaryValue,
  'mi': BacnetObjectType.multiStateInput,
  'mo': BacnetObjectType.multiStateOutput,
  'mv': BacnetObjectType.multiStateValue,
  'msi': BacnetObjectType.multiStateInput,
  'mso': BacnetObjectType.multiStateOutput,
  'msv': BacnetObjectType.multiStateValue,
  'dev': BacnetObjectType.device,
  'nc': BacnetObjectType.notificationClass,
  'sch': BacnetObjectType.schedule,
  'cal': BacnetObjectType.calendar,
  'tl': BacnetObjectType.trendLog,
};

/// Wrong command line arguments.
final class _UsageException implements Exception {
  _UsageException(this.message);

  final String message;
}

/// Runs the `bacnet` command line tool with [arguments]; returns the exit
/// code (0 success, 1 BACnet error, 64 usage error). [createClient] makes
/// the client (tests pass a `FakeBacnetClient`).
Future<int> runBacnetCli(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
  BacnetClient Function(BacnetConfig config)? createClient,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  final _Arguments args;
  try {
    args = _Arguments.parse(arguments);
  } on _UsageException catch (e) {
    errors
      ..writeln(e.message)
      ..writeln()
      ..write(_usage);
    return 64;
  }
  if (args.help || args.command == null) {
    output.write(_usage);
    return args.help ? 0 : 64;
  }
  const commands = {
    'discover',
    'read',
    'write',
    'objects',
    'describe',
    'watch',
    'routers',
  };
  final BacnetConfig config;
  try {
    if (!commands.contains(args.command)) {
      throw _UsageException('unknown command "${args.command}"');
    }
    config = BacnetConfig(
      interface: args.option('interface'),
      port: args.intOption('port') ?? BacnetConfig.defaultPort,
      requestTimeout: Duration(seconds: args.intOption('timeout') ?? 10),
      logLevel: BacnetLogLevel.error,
    );
  } on _UsageException catch (e) {
    errors
      ..writeln(e.message)
      ..writeln()
      ..write(_usage);
    return 64;
  }
  final client = (createClient ?? (config) => BacnetClient(config: config))(
    config,
  );
  try {
    await client.start();
    if (args.option('bbmd') case final bbmd?) {
      final (host, port) = _hostAndPort(bbmd);
      await client.registerForeignDevice(host, port: port);
    }
    final command = _Command(client, args, output);
    await switch (args.command!) {
      'discover' => command.discover(),
      'read' => command.read(),
      'write' => command.write(),
      'objects' => command.objects(),
      'describe' => command.describe(),
      'watch' => command.watch(),
      'routers' => command.routers(),
      final other => throw _UsageException('unknown command "$other"'),
    };
    return 0;
  } on _UsageException catch (e) {
    errors
      ..writeln(e.message)
      ..writeln()
      ..write(_usage);
    return 64;
  } on BacnetException catch (e) {
    errors.writeln(e);
    return 1;
  } finally {
    await client.close();
  }
}

/// Options and positional arguments.
final class _Arguments {
  _Arguments(this.options, this.positional, {required this.help});

  factory _Arguments.parse(List<String> arguments) {
    const aliases = {
      'i': 'interface',
      'p': 'port',
      'a': 'address',
      'h': 'help',
    };
    const flags = {'json', 'help'};
    const valued = {
      'interface',
      'port',
      'address',
      'bbmd',
      'timeout',
      'wait',
      'index',
      'priority',
      'output',
      'seconds',
    };
    final options = <String, String>{};
    final positional = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (argument == '--') {
        positional.addAll(arguments.skip(i + 1));
        break;
      }
      final String? name;
      if (argument.startsWith('--')) {
        name = argument.substring(2);
      } else if (argument.startsWith('-') &&
          argument.length == 2 &&
          !RegExp('[0-9]').hasMatch(argument[1])) {
        name =
            aliases[argument.substring(1)] ??
            (throw _UsageException('unknown option $argument'));
      } else {
        name = null;
      }
      if (name == null) {
        positional.add(argument);
      } else if (flags.contains(name)) {
        options[name] = 'true';
      } else if (valued.contains(name)) {
        if (i + 1 >= arguments.length) {
          throw _UsageException('$argument needs a value');
        }
        options[name] = arguments[++i];
      } else {
        throw _UsageException('unknown option $argument');
      }
    }
    return _Arguments(options, positional, help: options['help'] == 'true');
  }

  final Map<String, String> options;
  final List<String> positional;
  final bool help;

  String? get command => positional.isEmpty ? null : positional.first;

  bool get json => options['json'] == 'true';

  String? option(String name) => options[name];

  int? intOption(String name) {
    final value = options[name];
    if (value == null) return null;
    return int.tryParse(value) ??
        (throw _UsageException('--$name needs a number, not "$value"'));
  }

  /// Positional argument [index] after the command.
  String argument(int index, String what) {
    if (index + 1 >= positional.length) {
      throw _UsageException('${positional.first} needs $what');
    }
    return positional[index + 1];
  }

  String? optionalArgument(int index) =>
      index + 1 < positional.length ? positional[index + 1] : null;
}

final class _Command {
  _Command(this.client, this.args, this.out);

  final BacnetClient client;
  final _Arguments args;
  final StringSink out;

  Duration get _wait => Duration(seconds: args.intOption('wait') ?? 3);

  Future<int> _device() async {
    final text = args.argument(0, 'a device instance');
    final device = int.tryParse(text);
    if (device == null || device < 0 || device >= BacnetObject.maxInstance) {
      throw _UsageException('"$text" is not a device instance');
    }
    if (args.option('address') case final address?) {
      final (host, port) = _hostAndPort(address);
      await client.addDeviceBinding(device, host, port: port);
    }
    return device;
  }

  Future<void> discover() async {
    final devices = await DeviceScanner(client).discoverDevices(timeout: _wait);
    if (args.json) {
      out.writeln(
        jsonEncode([
          for (final d in devices)
            {
              'deviceId': d.deviceId,
              'name': d.deviceName,
              'vendorId': d.vendorId,
              'vendorName': d.vendorName,
              'modelName': d.modelName,
              'address': d.ipAddress == null
                  ? null
                  : '${d.ipAddress}:${d.port}',
              'network': d.networkNumber,
            },
        ]),
      );
      return;
    }
    for (final d in devices) {
      out.writeln(
        [
          '${d.deviceId}'.padLeft(7),
          (d.ipAddress == null ? '' : '${d.ipAddress}:${d.port}').padRight(21),
          if (d.networkNumber case final network? when network != 0)
            'net $network',
          d.deviceName ?? '',
          if (d.vendorName != null || d.modelName != null)
            '(${[d.vendorName, d.modelName].nonNulls.join(' ')})',
        ].join('  '),
      );
    }
    out.writeln('${devices.length} devices');
  }

  Future<void> read() async {
    final device = await _device();
    final object = _parseObject(args.argument(1, 'an object'));
    final property = _parseProperty(args.argument(2, 'a property'));
    final value = await client.readProperty(
      device,
      object.type,
      object.instance,
      property,
      arrayIndex: args.intOption('index') ?? -1,
    );
    out.writeln(
      args.json
          ? jsonEncode(value.toJson())
          : epicsValue(object, property, value),
    );
  }

  Future<void> write() async {
    final device = await _device();
    final object = _parseObject(args.argument(1, 'an object'));
    final property = _parseProperty(args.argument(2, 'a property'));
    final value = _parseValue(args.argument(3, 'a value'), object, property);
    final priority = args.intOption('priority') ?? 16;
    if (priority < 1 || priority > 16) {
      throw _UsageException('--priority must be 1..16');
    }
    await client.writeProperty(
      device,
      object.type,
      object.instance,
      property,
      value,
      priority: priority,
      arrayIndex: args.intOption('index') ?? -1,
    );
    out.writeln('wrote ${epicsValue(object, property, value)}');
  }

  Future<void> objects() async {
    final device = await _device();
    final objects = await DeviceScanner(client).scanDevice(
      device,
      propertyIds: const [BacnetPropertyId.objectName],
      maxObjects: 1 << 22,
    );
    if (args.json) {
      out.writeln(
        jsonEncode([
          for (final MapEntry(key: object, value: properties)
              in objects.entries)
            {
              'type': object.type.value,
              'instance': object.instance,
              'name': properties.valueOf(BacnetPropertyId.objectName)?.asString,
            },
        ]),
      );
      return;
    }
    for (final MapEntry(key: object, value: properties) in objects.entries) {
      final name = properties.valueOf(BacnetPropertyId.objectName)?.asString;
      out.writeln(
        '${epicsValue(object, BacnetPropertyId.objectIdentifier, object)}'
        '${name == null ? '' : '  "$name"'}',
      );
    }
    out.writeln('${objects.length} objects');
  }

  Future<void> describe() async {
    final device = await _device();
    final description = await client.describeDevice(device);
    final text = args.json
        ? const JsonEncoder.withIndent('  ').convert(description.toJson())
        : description.toEpics();
    if (args.option('output') case final path?) {
      await File(path).writeAsString(text);
      out.writeln('$description written to $path');
    } else {
      out.write(text);
      if (args.json) out.writeln();
    }
  }

  Future<void> watch() async {
    final device = await _device();
    final object = _parseObject(args.argument(1, 'an object'));
    final property = args.optionalArgument(2) == null
        ? BacnetPropertyId.presentValue
        : _parseProperty(args.optionalArgument(2)!);
    final seconds = args.intOption('seconds');
    final updates = PropertyMonitor(
      client,
    ).monitor(deviceId: device, object: object, propertyId: property);
    final done = Completer<void>();
    final subscription = updates.listen((update) {
      final time = update.timestamp.toIso8601String();
      switch (update) {
        case PropertyValueUpdate(:final value, :final source):
          out.writeln(
            args.json
                ? jsonEncode({
                    'time': time,
                    'source': source.name,
                    'value': value.toJson(),
                  })
                : '$time  ${epicsValue(object, property, value)}  '
                      '(${source.name})',
          );
        case PropertyErrorUpdate(:final error):
          out.writeln('$time  $error');
      }
    });
    final stop = seconds == null
        ? ProcessSignal.sigint.watch().first
        : Future<void>.delayed(Duration(seconds: seconds));
    unawaited(
      stop.then((_) {
        if (!done.isCompleted) done.complete();
      }),
    );
    await done.future;
    await subscription.cancel();
  }

  Future<void> routers() async {
    final routers = await client.discoverRouters(timeout: _wait);
    if (args.json) {
      out.writeln(
        jsonEncode([
          for (final r in routers)
            {'address': '${r.ipAddress}:${r.port}', 'networks': r.networks},
        ]),
      );
      return;
    }
    for (final r in routers) {
      out.writeln(
        '${r.ipAddress}:${r.port}  networks ${r.networks.join(', ')}',
      );
    }
    out.writeln('${routers.length} routers');
  }
}

(String, int) _hostAndPort(String text) {
  final colon = text.lastIndexOf(':');
  if (colon < 0) return (text, BacnetConfig.defaultPort);
  final port = int.tryParse(text.substring(colon + 1));
  if (port == null || port < 1 || port > 65535) {
    throw _UsageException('"$text" is not an address');
  }
  return (text.substring(0, colon), port);
}

/// `analog-input:1`, `ai:1`, `Analog Input:1` or `0:1`.
BacnetObject _parseObject(String text) {
  final colon = text.lastIndexOf(':');
  final instance = colon < 0 ? null : int.tryParse(text.substring(colon + 1));
  if (colon < 0 || instance == null || instance < 0 || instance > 0x3FFFFF) {
    throw _UsageException('"$text" is not an object (type:instance)');
  }
  final typeText = text.substring(0, colon).toLowerCase();
  final type =
      _objectAbbreviations[typeText] ??
      switch (int.tryParse(typeText)) {
        final number? when number >= 0 && number < 1024 => BacnetObjectType(
          number,
        ),
        _ =>
          BacnetObjectType.values
              .where((type) => epicsName(type.label) == epicsName(typeText))
              .firstOrNull,
      };
  if (type == null) throw _UsageException('unknown object type "$typeText"');
  return BacnetObject(type: type, instance: instance);
}

/// `present-value`, `Present Value` or `85`.
BacnetPropertyId _parseProperty(String text) {
  if (int.tryParse(text) case final number? when number >= 0) {
    return BacnetPropertyId(number);
  }
  final name = epicsName(text);
  return BacnetPropertyId.values
          .where((property) => epicsName(property.label) == name)
          .firstOrNull ??
      (throw _UsageException('unknown property "$text"'));
}

/// A value given on the command line, typed for [property] of [object].
BacnetValue _parseValue(
  String text,
  BacnetObject object,
  BacnetPropertyId property,
) {
  final colon = text.indexOf(':');
  if (colon > 0) {
    final content = text.substring(colon + 1);
    BacnetValue typed(BacnetValue? Function() parse) =>
        parse() ?? (throw _UsageException('"$text" is not a valid value'));
    switch (text.substring(0, colon)) {
      case 'real':
        return typed(
          () => switch (double.tryParse(content)) {
            final v? => BacnetReal(v),
            null => null,
          },
        );
      case 'double':
        return typed(
          () => switch (double.tryParse(content)) {
            final v? => BacnetDouble(v),
            null => null,
          },
        );
      case 'unsigned':
        return typed(
          () => switch (int.tryParse(content)) {
            final v? when v >= 0 => BacnetUnsigned(v),
            _ => null,
          },
        );
      case 'signed':
        return typed(
          () => switch (int.tryParse(content)) {
            final v? => BacnetSigned(v),
            null => null,
          },
        );
      case 'enum':
        return typed(
          () => switch (int.tryParse(content)) {
            final v? when v >= 0 => BacnetEnumerated(v),
            _ => null,
          },
        );
      case 'string':
        return BacnetCharacterString(content);
    }
  }
  final Object? plain = switch (text.toLowerCase()) {
    'null' => null,
    'true' || 'active' => true,
    'false' || 'inactive' => false,
    _ => int.tryParse(text) ?? double.tryParse(text) ?? text,
  };
  return BacnetValue.infer(
    plain,
    objectType: object.type,
    propertyId: property,
  );
}
