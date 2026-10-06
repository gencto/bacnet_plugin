// Native build hook: compiles bacnet-stack together with the plugin engine
// into one shared library for the target platform (Android, iOS, Linux,
// macOS and Windows) using the host C toolchain.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Pinned bacnet-stack sources, see `native/bacnet-stack` (git submodule).
const bacnetStackDir = 'native/bacnet-stack/';

/// bacnet-stack source directories compiled into the library.
const stackDirectories = <String>[
  'src/bacnet/',
  'src/bacnet/basic/binding/',
  'src/bacnet/basic/bbmd/',
  'src/bacnet/basic/object/',
  'src/bacnet/basic/service/',
  'src/bacnet/basic/sys/',
  'src/bacnet/basic/tsm/',
];

/// Individual bacnet-stack files compiled into the library.
const stackFiles = <String>[
  'src/bacnet/basic/npdu/h_npdu.c',
  'src/bacnet/basic/npdu/s_router.c',
  'src/bacnet/datalink/bvlc.c',
  'src/bacnet/datalink/bvlc6.c',
  'src/bacnet/datalink/cobs.c',
  'src/bacnet/datalink/crc.c',
];

/// Files excluded from the directories above (BACnet/SC needs OpenSSL).
const excludedStackFiles = <String>{'sc_netport.c'};

/// BACnet/IP port of the engine for POSIX systems.
const posixPort = 'bp_port_posix.c';

/// Platform files of the bacnet-stack Windows port.
const _win32PortFiles = <String>[
  'ports/win32/bip-init.c',
  'ports/win32/datetime-init.c',
  'ports/win32/mstimer-init.c',
];

/// Compile time limits of the stack, sized for large installations.
const stackDefines = <String, String?>{
  'BACDL_BIP': null,
  'BACNET_STACK_STATIC_DEFINE': null,
  'PRINT_ENABLED': '0',
  'MAX_TSM_TRANSACTIONS': '255',
  'MAX_COV_SUBSCRIPTIONS': '1024',
  'MAX_COV_ADDRESSES': '128',
  // alarms and events of the server: event algorithms of analog and binary
  // objects, 64 Notification Class instances (0..63)
  'INTRINSIC_REPORTING': null,
  'BINARY_INPUT_INTRINSIC_REPORTING': '1',
  'BINARY_VALUE_INTRINSIC_REPORTING': '1',
  'MAX_NOTIFICATION_CLASSES': '64',
  // schedules of the server: members written and exceptions
  'BACNET_SCHEDULE_OBJ_PROP_REF_SIZE': '32',
  'BACNET_EXCEPTION_SCHEDULE_SIZE': '16',
  // channels of the server: members and control groups
  'CHANNEL_MEMBERS_MAX': '32',
  'CONTROL_GROUPS_MAX': '16',
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    final packageRoot = input.packageRoot;
    final stackRoot = packageRoot.resolve(bacnetStackDir);
    final stackSrc = Directory.fromUri(stackRoot.resolve('src/bacnet/'));
    if (!stackSrc.existsSync()) {
      throw StateError(
        'bacnet-stack sources not found in ${stackRoot.toFilePath()}. '
        'Run `git submodule update --init` in the bacnet_plugin package.',
      );
    }

    final engineDir = Directory.fromUri(packageRoot.resolve('native/src/'));
    final pubspec = File.fromUri(packageRoot.resolve('pubspec.yaml'));
    final targetOS = input.config.code.targetOS;
    final isWindows = targetOS == OS.windows;
    final isApple = targetOS == OS.macOS || targetOS == OS.iOS;

    final sources = <String>[
      for (final dir in stackDirectories)
        ..._cFiles(Directory.fromUri(stackRoot.resolve(dir))),
      for (final file in stackFiles) stackRoot.resolve(file).toFilePath(),
      if (isWindows)
        for (final file in _win32PortFiles)
          stackRoot.resolve(file).toFilePath(),
      // the engine; bp_port_posix.c replaces the stack port on POSIX systems
      for (final file in _cFiles(engineDir))
        if (!isWindows || !file.endsWith(posixPort)) file,
    ];

    final builder = CBuilder.library(
      name: 'bacnet_plugin',
      assetName: 'src/native/bindings.g.dart',
      sources: sources,
      includes: [
        stackRoot.resolve('src/').toFilePath(),
        packageRoot.resolve('native/src/').toFilePath(),
        if (isWindows) stackRoot.resolve('ports/win32/').toFilePath(),
      ],
      defines: {
        ...stackDefines,
        'BP_ENGINE_VERSION': _packageVersion(pubspec),
        if (isWindows) ...{
          'BACNET_IP_BROADCAST_USE_INADDR_ANY': null,
          '_CRT_SECURE_NO_WARNINGS': null,
          '_CRT_NONSTDC_NO_DEPRECATE': null,
          '_WINSOCK_DEPRECATED_NO_WARNINGS': null,
        },
      },
      flags: [
        if (isWindows) ...[
          '/W0',
          '/Gy',
        ] else ...[
          // The stack is third party code: keep build logs readable.
          '-w',
          '-fvisibility=hidden',
          '-ffunction-sections',
          '-fdata-sections',
          if (isApple) '-Wl,-dead_strip' else '-Wl,--gc-sections',
        ],
      ],
      libraries: [
        if (isWindows) ...['ws2_32', 'iphlpapi', 'winmm'],
        if (targetOS == OS.linux || targetOS == OS.android) 'm',
      ],
    );

    await builder.run(
      input: input,
      output: output,
      logger: Logger.detached('bacnet_plugin')
        ..level = Level.SEVERE
        ..onRecord.listen((record) => stderr.writeln(record.message)),
    );

    // Sources are tracked by the builder; headers and the version are not.
    output.dependencies.addAll([
      pubspec.uri,
      for (final header in engineDir.listSync().whereType<File>())
        if (header.path.endsWith('.h')) header.uri,
    ]);
  });
}

List<String> _cFiles(Directory directory) {
  final files =
      directory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.c'))
          .where(
            (file) => !excludedStackFiles.contains(file.uri.pathSegments.last),
          )
          .map((file) => file.path)
          .toList()
        ..sort();
  return files;
}

/// Version of this package, compiled into `bacnet_plugin_version()`.
String _packageVersion(File pubspec) {
  final match = RegExp(
    r'^version:\s*([0-9A-Za-z.+-]+)',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync());
  if (match == null) {
    throw StateError('no version in ${pubspec.path}');
  }
  return match.group(1)!;
}
