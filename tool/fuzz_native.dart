// Builds the libFuzzer target of the engine (native/fuzz/fuzz_npdu.c) with
// AddressSanitizer and UndefinedBehaviorSanitizer from the sources and
// defines of hook/build.dart, seeds a corpus and runs it.
//
// Usage: dart run tool/fuzz_native.dart [seconds] [-- libFuzzer options]
// Needs clang with the libFuzzer runtime (Debian/Ubuntu: libclang-rt-dev).
// Crashes are written to build/fuzz/ (crash-*); reproduce one with
// build/fuzz/fuzz_npdu build/fuzz/crash-....
// ignore_for_file: avoid_print
import 'dart:io';

import '../hook/build.dart' as hook;

/// Seeds: control byte (bit 0 from the bound device, bit 1 invoke id of the
/// open request, bits 2-4 the open request) and an NPDU.
const _seeds = <String, String>{
  'who-is': '00 0120ffff00ff 1008',
  'read-property': '00 0104 0005010c 0c0000000119 55',
  'read-property-multiple':
      '00 0104 0005020e 0c000000011e09081f 0c020004d21e094b09611f',
  'write-property': '00 0104 0005030f 0c0080000119552e44420c00002f 3908',
  'write-property-multiple':
      '00 0104 00050410 0c008000011e09552e4441a000002f1f',
  'subscribe-cov': '00 0104 00050505 0901 1c00000001 2901 3978',
  'subscribe-cov-property':
      '00 0104 0005061c 0901 1c00000001 2901 3978 4e09551f 5c3dcccccd',
  'read-range-trend-log': '00 0104 0005071a 0c05000001 1983 3e2101 3105 3f',
  'atomic-read-file': '00 0104 00050806 c402800001 0e3100 2164 0f',
  'atomic-write-file': '00 0104 00050907 c402800001 0e3100 650568656c6c6f 0f',
  'create-object': '00 0104 00050a0a 0e09020f 1e0955 2e4441200000 2f1f',
  'delete-object': '00 0104 00050b0b c400800002',
  'add-list-element': '00 0104 00050c08 0c03c00001 1966 3e 0e0c020004d20f 3f',
  'acknowledge-alarm':
      '00 0104 00050d00 0901 1c00000001 2902 3e0901 3f 4900 5e0901 5f',
  'get-event-information': '00 0104 00050e1d',
  'get-alarm-summary': '00 0104 00050f03',
  'dcc': '00 0104 0005101109021900 2d0500 66757a7a',
  'reinitialize-backup': '00 0104 00051114 0903 1d0500 66757a7a',
  'private-transfer': '00 0104 00051212 0a0104 1901 2e21052f',
  'text-message': '00 0104 00051313 0c020004d2 2900 3d050068656c6c6f',
  'who-has': '00 0120ffff00ff 1007 3d0500 66757a7a',
  'write-group': '00 0100 100a 091719082e09072e44429700002f2f2f 3901',
  'who-am-i': '00 0100 100d 22010475030052 43 31 75050053 4e 31 32',
  'you-are': '00 0100 100e 220104 7503005243 31 750500534e3132 c4020004d2',
  'i-am': '00 0100 1000 c4020004d2 2205c4 9103 220104',
  'cov-notification':
      '01 0100 1002 0901 1c020004d2 2c00000001 3978 4e09552e44420000002f4f',
  'cov-notification-multiple':
      '01 0100 100b 0907 1c020004d2 2978 4e0c000000011e09552e4441ac00002f1f4f',
  'event-notification':
      '01 0100 1003 0901 1c020004d2 2c00000001 3e0c0d1e2d2f3f 4901 5900 6900 '
      '8900 9900 a900 b900',
  'complex-ack-read-property': '03 0100 3000 0c 0c00000001 1955 3e4441ac00003f',
  'complex-ack-segmented': '03 0100 3c000002000c 0c00000001 1955 3e44',
  'simple-ack-subscribe-multiple': '13 0100 20001e',
  'error-subscribe-multiple':
      '13 0100 50001e 0e910591000f 1e0c00000001 1e09551f 2e910291202f 1f',
  'reject': '03 0100 6000 09',
  'abort': '03 0100 7000 04',
  'routed-read-property':
      '00 010c 0005 06 c0a80101bac0 0005130c 0c0000000119 55',
  'network-message-who-is-router': '00 0180 00',
};

Future<void> main(List<String> args) async {
  final separator = args.indexOf('--');
  final ours = separator < 0 ? args : args.sublist(0, separator);
  final libFuzzer = separator < 0 ? <String>[] : args.sublist(separator + 1);
  final seconds = ours.isEmpty ? 60 : int.parse(ours.first);

  final root = Directory.current.uri;
  final out = Directory.fromUri(root.resolve('build/fuzz/'))
    ..createSync(recursive: true);
  final stack = root.resolve(hook.bacnetStackDir);
  final sources = [
    for (final dir in hook.stackDirectories)
      ..._cFiles(Directory.fromUri(stack.resolve(dir))),
    for (final file in hook.stackFiles) stack.resolve(file).toFilePath(),
    ..._cFiles(Directory.fromUri(root.resolve('native/src/'))),
    root.resolve('native/fuzz/fuzz_npdu.c').toFilePath(),
  ];
  final binary = '${out.path}fuzz_npdu';
  print('building $binary from ${sources.length} files');
  final build = await Process.run('clang', [
    '-g',
    '-O1',
    '-fsanitize=fuzzer,address,undefined',
    '-fno-sanitize-recover=undefined',
    '-w',
    for (final MapEntry(key: name, value: value) in hook.stackDefines.entries)
      value == null ? '-D$name' : '-D$name=$value',
    '-DBP_ENGINE_VERSION=fuzz',
    '-I${stack.resolve('src/').toFilePath()}',
    '-I${root.resolve('native/src/').toFilePath()}',
    ...sources,
    '-lm',
    '-o',
    binary,
  ]);
  if (build.exitCode != 0) {
    stderr
      ..write(build.stdout)
      ..write(build.stderr);
    exit(build.exitCode);
  }

  final corpus = Directory('${out.path}corpus')..createSync();
  for (final MapEntry(key: name, value: hex) in _seeds.entries) {
    final digits = hex.replaceAll(' ', '');
    File('${corpus.path}/$name').writeAsBytesSync([
      for (var i = 0; i + 1 < digits.length; i += 2)
        int.parse(digits.substring(i, i + 2), radix: 16),
    ]);
  }
  print('fuzzing for $seconds s');
  final fuzz = await Process.start(
    binary,
    [
      '-max_total_time=$seconds',
      '-use_value_profile=1',
      '-artifact_prefix=${out.path}',
      ...libFuzzer,
      corpus.path,
    ],
    mode: ProcessStartMode.inheritStdio,
    environment: {
      'ASAN_OPTIONS': 'detect_leaks=1:abort_on_error=1',
      'UBSAN_OPTIONS': 'print_stacktrace=1',
    },
  );
  exit(await fuzz.exitCode);
}

List<String> _cFiles(Directory directory) => [
  for (final file in directory.listSync().whereType<File>())
    if (file.path.endsWith('.c') &&
        !hook.excludedStackFiles.contains(file.uri.pathSegments.last))
      file.path,
]..sort();
