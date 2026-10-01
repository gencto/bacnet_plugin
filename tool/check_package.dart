// Checks that the package builds as it is published: copies the files that
// `dart pub publish --dry-run` lists into a temporary directory and runs an
// application that depends on that copy, so the build hook compiles and
// loads the native library from the published files only (pub leaves out
// what .pubignore excludes and what the checkout lacks, such as an
// uninitialized bacnet-stack submodule).
//
// Usage: dart run tool/check_package.dart [--keep]
// ignore_for_file: avoid_print
import 'dart:io';

Future<void> main(List<String> args) async {
  final root = File.fromUri(Platform.script).parent.parent;
  final dart = Platform.resolvedExecutable;

  final dryRun = await Process.run(dart, [
    'pub',
    'publish',
    '--dry-run',
  ], workingDirectory: root.path);
  final files = _publishedFiles(dryRun.stdout as String);
  if (files.isEmpty) {
    _fail(
      'no files in the output of dart pub publish --dry-run:\n'
      '${dryRun.stdout}\n${dryRun.stderr}',
    );
  }
  if (!files.any((f) => f.startsWith('native/bacnet-stack/src/bacnet/'))) {
    _fail(
      'the package does not contain the bacnet-stack sources: run '
      '`git submodule update --init`',
    );
  }

  final temp = await Directory.systemTemp.createTemp('bacnet_plugin_package');
  final package = Directory('${temp.path}/bacnet_plugin');
  for (final file in files) {
    final target = File('${package.path}/$file');
    await target.parent.create(recursive: true);
    await File('${root.path}/$file').copy(target.path);
  }
  print('copied ${files.length} published files to ${package.path}');

  final app = Directory('${temp.path}/app');
  await Directory('${app.path}/bin').create(recursive: true);
  await File('${app.path}/pubspec.yaml').writeAsString('''
name: package_check
publish_to: none
environment:
  sdk: ^3.10.0
dependencies:
  bacnet_plugin:
    path: ../bacnet_plugin
''');
  final port = 40000 + DateTime.now().millisecondsSinceEpoch % 20000;
  await File('${app.path}/bin/main.dart').writeAsString('''
import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';

Future<void> main() async {
  final client = BacnetClient(
    config: const BacnetConfig(interface: '127.0.0.1', port: $port),
  );
  await client.start();
  print('native library \${client.nativeVersion}');
  await client.close();
  exit(0);
}
''');

  for (final command in [
    ['pub', 'get'],
    ['run', 'bin/main.dart'],
  ]) {
    final result = await Process.run(dart, command, workingDirectory: app.path);
    stdout.write(result.stdout);
    if (result.exitCode != 0) {
      stderr.write(result.stderr);
      _fail(
        'dart ${command.join(' ')} failed (exit ${result.exitCode}); '
        'the package is in ${temp.path}',
      );
    }
  }
  if (args.contains('--keep')) {
    print('kept ${temp.path}');
  } else {
    await temp.delete(recursive: true);
  }
  print('the published files build and load the native library');
}

/// The paths of the files in the tree `dart pub publish --dry-run` prints.
List<String> _publishedFiles(String output) {
  final files = <String>[];
  final directories = <String>[];
  var inTree = false;
  for (final line in output.split('\n')) {
    if (line.startsWith('Publishing ')) {
      inTree = true;
      continue;
    }
    if (!inTree) continue;
    // unicode tree, or the ASCII tree pub prints without unicode output
    final match = RegExp(
      r"^((?:│   |\|   |    )*)(?:├── |└── |\|-- |'-- |`-- )(.+)$",
    ).firstMatch(line.trimRight());
    if (match == null) {
      if (line.trim().isEmpty || line.startsWith('Total compressed')) break;
      continue;
    }
    final depth = match.group(1)!.length ~/ 4;
    var name = match.group(2)!;
    if (name.contains(' more)') || name.startsWith('...')) {
      _fail('pub shortened the file list: $line');
    }
    final size = RegExp(r' \((?:<?\d+(?:\.\d+)? ?[KMG]?B)\)$').firstMatch(name);
    directories.length = depth;
    if (size == null) {
      directories.add(name);
      continue;
    }
    name = name.substring(0, size.start);
    files.add([...directories, name].join('/'));
  }
  return files;
}

Never _fail(String message) {
  stderr.writeln('check_package: $message');
  exit(1);
}
