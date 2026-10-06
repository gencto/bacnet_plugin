// The bacnet command line tool: dart run bacnet_plugin:bacnet --help
import 'dart:io';

import 'package:bacnet_plugin/src/cli/bacnet_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runBacnetCli(arguments);
}
