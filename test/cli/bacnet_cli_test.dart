import 'dart:convert';
import 'dart:io';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/cli/bacnet_cli.dart';
import 'package:bacnet_plugin/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeBacnetDevice ahu;
  late FakeBacnetClient client;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    ahu = FakeBacnetDevice(1234, name: 'AHU-1', vendorId: 7)
      ..addObject(
        BacnetObjectType.analogInput,
        1,
        name: 'Supply',
        presentValue: const BacnetReal(21.5),
        units: BacnetEngineeringUnits.degreesCelsius,
      )
      ..addObject(
        BacnetObjectType.analogValue,
        1,
        name: 'Setpoint',
        presentValue: const BacnetReal(20),
      )
      ..addObject(
        BacnetObjectType.binaryValue,
        1,
        name: 'Fan',
        presentValue: const BacnetEnumerated(0),
      );
    client = FakeBacnetClient(
      devices: [ahu],
      routers: [
        FakeBacnetRouter('10.0.0.1', networks: [5, 6]),
      ],
    );
    out = StringBuffer();
    err = StringBuffer();
  });

  Future<int> run(List<String> arguments) =>
      runBacnetCli(arguments, out: out, err: err, createClient: (_) => client);

  test('prints the usage', () async {
    expect(await run(['--help']), 0);
    expect(out.toString(), contains('Usage: bacnet'));
    expect(await run([]), 64);
  });

  test('refuses wrong arguments', () async {
    expect(await run(['explode']), 64);
    expect(err.toString(), contains('unknown command "explode"'));
    err.clear();
    expect(await run(['read', '1234', 'ai-1', 'present-value']), 64);
    expect(err.toString(), contains('"ai-1" is not an object'));
    err.clear();
    expect(await run(['read', '1234', 'ai:1', 'no-such-property']), 64);
    expect(err.toString(), contains('unknown property'));
    err.clear();
    expect(await run(['read', '1234']), 64);
    expect(err.toString(), contains('read needs an object'));
    err.clear();
    expect(await run(['--port']), 64);
    expect(err.toString(), contains('--port needs a value'));
    err.clear();
    expect(await run(['--port', 'abc', 'discover']), 64);
    expect(err.toString(), contains('--port needs a number'));
  });

  test('discovers devices', () async {
    expect(await run(['discover', '--wait', '1']), 0);
    expect(out.toString(), contains('1234'));
    expect(out.toString(), contains('AHU-1'));
    expect(out.toString(), contains('1 devices'));
  });

  test('reads properties', () async {
    expect(await run(['read', '1234', 'ai:1', 'present-value']), 0);
    expect(out.toString(), '21.5\n');
    out.clear();
    expect(await run(['read', '1234', 'analog-input:1', 'units']), 0);
    expect(out.toString(), 'degrees-celsius\n');
    out.clear();
    expect(await run(['--json', 'read', '1234', '0:1', '85']), 0);
    expect(jsonDecode(out.toString()), {'datatype': 'real', 'value': 21.5});
  });

  test('reports BACnet errors', () async {
    expect(await run(['read', '1234', 'ai:9', 'present-value']), 1);
    expect(err.toString(), contains('Unknown Object'));
  });

  test('writes properties typed for the property', () async {
    expect(
      await run([
        'write',
        '1234',
        'av:1',
        'present-value',
        '42',
        '--priority',
        '8',
      ]),
      0,
    );
    expect(
      ahu.object(
        BacnetObjectType.analogValue,
        1,
      )![BacnetPropertyId.presentValue],
      const BacnetReal(42),
    );
    expect(client.requests.last.priority, 8);
    expect(await run(['write', '1234', 'bv:1', 'present-value', 'active']), 0);
    expect(client.requests.last.value, const BacnetEnumerated(1));
    expect(await run(['write', '1234', 'av:1', 'object-name', 'string:42']), 0);
    expect(client.requests.last.value, const BacnetCharacterString('42'));
    expect(await run(['write', '1234', 'av:1', 'present-value', 'real:x']), 64);
  });

  test('lists objects', () async {
    expect(await run(['objects', '1234']), 0);
    final lines = out.toString().split('\n');
    expect(lines, contains('(analog-input, 1)  "Supply"'));
    expect(lines, contains('4 objects'));
  });

  test('describes devices', () async {
    expect(await run(['--json', 'describe', '1234']), 0);
    final description = BacnetDeviceDescription.fromJson(
      jsonDecode(out.toString()) as Map<String, Object?>,
    );
    expect(description.objects, hasLength(4));

    final directory = await Directory.systemTemp.createTemp('bacnet_cli');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/ahu.tpi';
    out.clear();
    expect(await run(['describe', '1234', '--output', path]), 0);
    expect(out.toString(), contains('written to $path'));
    expect(
      await File(path).readAsString(),
      contains('    object-name: "Setpoint"\n'),
    );
  });

  test('watches a property', () async {
    expect(await run(['watch', '1234', 'ai:1', '--seconds', '1']), 0);
    expect(out.toString(), contains('21.5  (manual)'));
  });

  test('lists routers', () async {
    expect(await run(['routers', '--wait', '1']), 0);
    expect(out.toString(), contains('10.0.0.1:47808  networks 5, 6'));
  });
}
