// Generates the BACnet constants in lib/src/constants from the enumerations
// of the bundled bacnet-stack (native/bacnet-stack/src/bacnet/bacenum.h).
//
// Usage: dart run tool/generate_constants.dart
//
// Names are derived from the C identifiers (OBJECT_ANALOG_INPUT ->
// analogInput, "Analog Input"); the tables below only list exceptions.
// ignore_for_file: avoid_print
import 'dart:io';

const String _header = 'native/bacnet-stack/src/bacnet/bacenum.h';
const String _outputDir = 'lib/src/constants';

/// Words rendered in a fixed spelling in labels.
const Map<String, String> _labelWords = {
  'apdu': 'APDU',
  'bacnet': 'BACnet',
  'bbmd': 'BBMD',
  'btu': 'BTU',
  'btus': 'BTUs',
  'cov': 'COV',
  'dhcp': 'DHCP',
  'dns': 'DNS',
  'fd': 'FD',
  'hvac': 'HVAC',
  'id': 'ID',
  'ip': 'IP',
  'ipv6': 'IPv6',
  'lan': 'LAN',
  'mac': 'MAC',
  'mstp': 'MS/TP',
  'npdu': 'NPDU',
  'pv': 'PV',
  'sc': 'SC',
  'tsm': 'TSM',
  'udp': 'UDP',
  'utc': 'UTC',
  'uuid': 'UUID',
  'vmac': 'VMAC',
  'vt': 'VT',
};

const List<_File> _files = [
  _File('object_types.dart', [
    _Enum(
      'BacnetObjectType',
      cEnum: 'BACNET_OBJECT_TYPE',
      prefix: 'OBJECT_',
      doc: 'BACnet object types (BACnetObjectType).',
      unknown: r'Unknown ($value)',
      maxValue: 127,
      names: {
        'TRENDLOG': 'trendLog',
        'BITSTRING_VALUE': 'bitStringValue',
        'CHARACTERSTRING_VALUE': 'characterStringValue',
        'OCTETSTRING_VALUE': 'octetStringValue',
        'DATETIME_PATTERN_VALUE': 'dateTimePatternValue',
        'DATETIME_VALUE': 'dateTimeValue',
      },
      labels: {
        'TRENDLOG': 'Trend Log',
        'BITSTRING_VALUE': 'BitString Value',
        'CHARACTERSTRING_VALUE': 'CharacterString Value',
        'OCTETSTRING_VALUE': 'OctetString Value',
        'DATETIME_PATTERN_VALUE': 'DateTime Pattern Value',
        'DATETIME_VALUE': 'DateTime Value',
        'MULTI_STATE_INPUT': 'Multi-state Input',
        'MULTI_STATE_OUTPUT': 'Multi-state Output',
        'MULTI_STATE_VALUE': 'Multi-state Value',
      },
    ),
  ]),
  _File('property_ids.dart', [
    _Enum(
      'BacnetPropertyId',
      cEnum: 'BACNET_PROPERTY_ID',
      prefix: 'PROP_',
      doc: 'BACnet property identifiers (BACnetPropertyIdentifier).',
      unknown: r'Property $value',
      skip: {'BLANK_1'},
      names: {},
      labels: {},
    ),
  ]),
  _File('errors.dart', [
    _Enum(
      'BacnetErrorClass',
      cEnum: 'BACNET_ERROR_CLASS',
      prefix: 'ERROR_CLASS_',
      doc: 'BACnet error classes (BACnetErrorClass).',
      unknown: r'Unknown Class ($value)',
    ),
    _Enum(
      'BacnetErrorCode',
      cEnum: 'BACNET_ERROR_CODE',
      prefix: 'ERROR_CODE_',
      doc: 'BACnet error codes (BACnetErrorCode).',
      unknown: r'Error Code $value',
      maxValue: 255,
      names: {'KEY_GENERATION_ERROR': 'keyGeneration'},
    ),
    _Enum(
      'BacnetAbortReason',
      cEnum: 'BACNET_ABORT_REASON',
      prefix: 'ABORT_REASON_',
      doc: 'BACnet abort reasons (BACnetAbortReason).',
      unknown: r'Abort Reason $value',
    ),
    _Enum(
      'BacnetRejectReason',
      cEnum: 'BACNET_REJECT_REASON',
      prefix: 'REJECT_REASON_',
      doc: 'BACnet reject reasons (BACnetRejectReason).',
      unknown: r'Reject Reason $value',
    ),
  ]),
  _File('services.dart', [
    _Enum(
      'BacnetConfirmedService',
      cEnum: 'BACNET_CONFIRMED_SERVICE',
      prefix: 'SERVICE_CONFIRMED_',
      doc: 'BACnet confirmed service choices (BACnetConfirmedServiceChoice).',
      unknown: r'Confirmed Service $value',
      names: {
        'READ_PROP_CONDITIONAL': 'readPropertyConditional',
        'READ_PROP_MULTIPLE': 'readPropertyMultiple',
        'WRITE_PROP_MULTIPLE': 'writePropertyMultiple',
        'AUTH_REQUEST': 'authorizationRequest',
      },
    ),
    _Enum(
      'BacnetUnconfirmedService',
      cEnum: 'BACNET_UNCONFIRMED_SERVICE',
      prefix: 'SERVICE_UNCONFIRMED_',
      doc:
          'BACnet unconfirmed service choices '
          '(BACnetUnconfirmedServiceChoice).',
      unknown: r'Unconfirmed Service $value',
    ),
  ]),
  _File('engineering_units.dart', [
    _Enum(
      'BacnetEngineeringUnits',
      cEnum: 'BACNET_ENGINEERING_UNITS',
      prefix: 'UNITS_',
      doc: 'BACnet engineering units (BACnetEngineeringUnits).',
      unknown: r'Units $value',
    ),
  ]),
  _File('enumerations.dart', [
    _Enum(
      'BacnetEventState',
      cEnum: 'BACNET_EVENT_STATE',
      prefix: 'EVENT_STATE_',
      doc: 'BACnet event states (BACnetEventState).',
      unknown: r'Event State $value',
      names: {'OFFNORMAL': 'offNormal'},
      labels: {'OFFNORMAL': 'Off Normal'},
    ),
    _Enum(
      'BacnetReliability',
      cEnum: 'BACNET_RELIABILITY',
      prefix: 'RELIABILITY_',
      doc: 'BACnet reliability values (BACnetReliability).',
      unknown: r'Reliability $value',
      names: {'RENEW_FD_REGISTRATION_FAILURE': 'renewFdRegistrationFailure'},
    ),
    _Enum(
      'BacnetDeviceStatus',
      cEnum: 'BACNET_DEVICE_STATUS',
      prefix: 'STATUS_',
      doc: 'BACnet device status values (BACnetDeviceStatus).',
      unknown: r'Device Status $value',
    ),
    _Enum(
      'BacnetSegmentation',
      cEnum: 'BACNET_SEGMENTATION',
      prefix: 'SEGMENTATION_',
      doc: 'BACnet segmentation support (BACnetSegmentation).',
      unknown: r'Segmentation $value',
    ),
  ]),
];

/// Reserved words that cannot be used as identifiers.
const Set<String> _reserved = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', //
  'default', 'do', 'else', 'enum', 'extends', 'false', 'final', 'finally',
  'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super',
  'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};

class _File {
  const _File(this.name, this.enums);

  final String name;
  final List<_Enum> enums;
}

class _Enum {
  const _Enum(
    this.dartName, {
    required this.cEnum,
    required this.prefix,
    required this.doc,
    required this.unknown,
    this.names = const {},
    this.labels = const {},
    this.skip = const {},
    this.maxValue,
  });

  final String dartName;
  final String cEnum;
  final String prefix;
  final String doc;

  /// Label of unknown values; `$value` is replaced by the value.
  final String unknown;

  /// Dart names that differ from the derived ones (C name without prefix).
  final Map<String, String> names;

  /// Labels that differ from the derived ones.
  final Map<String, String> labels;

  /// Entries to leave out (C name without prefix).
  final Set<String> skip;

  /// Largest standard value; larger ones are library internal.
  final int? maxValue;
}

typedef _Entry = ({String name, String label, int value});

void main() {
  final source = File(_header).readAsStringSync();
  final written = <String>[];
  for (final file in _files) {
    final out = StringBuffer()
      ..writeln('// GENERATED by tool/generate_constants.dart from')
      ..writeln('// bacnet-stack bacenum.h. Do not edit.')
      ..writeln();
    for (final (index, spec) in file.enums.indexed) {
      if (index > 0) out.writeln();
      _writeClass(out, spec, _entries(source, spec));
    }
    final path = '$_outputDir/${file.name}';
    File(path).writeAsStringSync(out.toString());
    written.add(path);
  }
  final format = Process.runSync('dart', ['format', ...written]);
  if (format.exitCode != 0) {
    stderr.write(format.stderr);
    exit(format.exitCode);
  }
  print('Generated ${written.join(', ')}');
}

List<_Entry> _entries(String source, _Enum spec) {
  final body = RegExp(
    r'typedef enum\s*\w*\s*\{([^}]*)\}\s*' + spec.cEnum + r'\s*;',
  ).firstMatch(source);
  if (body == null) throw StateError('enum ${spec.cEnum} not found');
  final text = body
      .group(1)!
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp('//.*'), '');
  final entries = <_Entry>[];
  final seenValues = <int>{};
  final seenNames = <String>{};
  for (final item in text.split(',')) {
    final match = RegExp(
      r'^\s*([A-Z][A-Z0-9_]*)\s*(?:=\s*(\S+))?\s*$',
    ).firstMatch(item);
    if (match == null) {
      if (item.trim().isEmpty) continue;
      throw FormatException('unexpected entry in ${spec.cEnum}', item);
    }
    final cName = match.group(1)!;
    if (!cName.startsWith(spec.prefix) || _isMarker(cName)) continue;
    final key = cName.substring(spec.prefix.length);
    if (spec.skip.contains(key)) continue;
    final literal = match.group(2);
    final value = literal == null ? null : int.tryParse(literal);
    if (value == null) {
      throw FormatException('no literal value for $cName', item);
    }
    if (key.isEmpty || value > (spec.maxValue ?? value)) continue;
    // keep the first name of aliases
    if (!seenValues.add(value)) continue;
    final name = spec.names[key] ?? _camelCase(key);
    if (_reserved.contains(name) || !seenNames.add(name)) {
      throw StateError('invalid or duplicate name $name for $cName');
    }
    entries.add((
      name: name,
      label: spec.labels[key] ?? _label(key),
      value: value,
    ));
  }
  final unused = {
    ...spec.names.keys,
    ...spec.labels.keys,
    ...spec.skip,
  }.where((key) => !source.contains('${spec.prefix}$key'));
  if (unused.isNotEmpty) {
    throw StateError('${spec.dartName}: stale overrides $unused');
  }
  return entries..sort((a, b) => a.value.compareTo(b.value));
}

/// Range markers and limits, not values.
bool _isMarker(String name) =>
    name.startsWith('MAX_') ||
    name.contains('RESERVED') ||
    name.contains('PROPRIETARY') ||
    RegExp(r'_(MIN|MAX|FIRST|LAST)$').hasMatch(name);

String _camelCase(String key) {
  final words = key.toLowerCase().split('_');
  return words.first +
      words.skip(1).map((w) => w[0].toUpperCase() + w.substring(1)).join();
}

String _label(String key) => key
    .toLowerCase()
    .split('_')
    .map((w) => _labelWords[w] ?? w[0].toUpperCase() + w.substring(1))
    .join(' ');

void _writeClass(StringBuffer out, _Enum spec, List<_Entry> entries) {
  out
    ..writeln('/// ${spec.doc}')
    ..writeln('abstract final class ${spec.dartName} {');
  for (final entry in entries) {
    out
      ..writeln('  /// ${entry.label}.')
      ..writeln('  static const int ${entry.name} = ${entry.value};')
      ..writeln();
  }
  out
    ..writeln('  static const Map<int, String> _labels = {')
    ..writeAll(entries.map((e) => "    ${e.name}: '${e.label}',\n"))
    ..writeln('  };')
    ..writeln()
    ..writeln('  /// All values defined by this library.')
    ..writeln('  static Iterable<int> get values => _labels.keys;')
    ..writeln()
    ..writeln('  /// Human readable name of [value].')
    ..writeln('  static String getName(int value) =>')
    ..writeln("      _labels[value] ?? '${spec.unknown}';")
    ..writeln('}');
}
