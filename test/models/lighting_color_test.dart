import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

import '../support/codec_helpers.dart';

/// Encodes [value] like a property value and decodes it like a read.
BacnetValue _wire(BacnetValue value) => roundTrip(value);

Matcher _malformed() => throwsA(isA<BacnetDecodeException>());

String _encoded(BacnetValue value) {
  final writer = BacnetWriter();
  encodeApplicationValue(writer, value);
  return hex(writer.toBytes());
}

void main() {
  test('BacnetLightingCommand fade matches bacnet-stack', () {
    const command = BacnetLightingCommand(
      operation: BacnetLightingOperation.fadeTo,
      targetLevel: 80,
      fadeTime: Duration(seconds: 2),
    );
    // bacnet-stack lighting_command_encode(): [0] enum, [1] REAL, [4] Unsigned
    expect(_encoded(command.toValue()), '09 01 1c 42 a0 00 00 4a 07 d0');
    expect(BacnetLightingCommand.fromValue(_wire(command.toValue())), command);
  });

  test('BacnetLightingCommand all fields round-trip', () {
    const command = BacnetLightingCommand(
      operation: BacnetLightingOperation.rampTo,
      targetLevel: 42.5,
      rampRate: 10,
      stepIncrement: 5,
      fadeTime: Duration(milliseconds: 3000),
      priority: 8,
    );
    expect(BacnetLightingCommand.fromValue(_wire(command.toValue())), command);
  });

  test('BacnetLightingCommand without optional fields', () {
    const command = BacnetLightingCommand(
      operation: BacnetLightingOperation.stop,
    );
    expect(_encoded(command.toValue()), '09 0a');
    expect(BacnetLightingCommand.fromValue(_wire(command.toValue())), command);
  });

  test('BacnetLightingCommand rejects a malformed value', () {
    expect(
      () => BacnetLightingCommand.fromValue(const BacnetReal(1)),
      _malformed(),
    );
  });

  test('BacnetXYColor matches bacnet-stack', () {
    // bacnet-stack xy_color_encode() of (0.3, 0.4) as two application REALs
    expect(
      _encoded(const BacnetXYColor(0.3, 0.4).toValue()),
      '44 3e 99 99 9a 44 3e cc cc cd',
    );
    // round-trip with values exactly representable as 32-bit REAL
    const color = BacnetXYColor(0.5, 0.25);
    expect(BacnetXYColor.fromValue(_wire(color.toValue())), color);
    expect(
      () => BacnetXYColor.fromValue(const BacnetList([BacnetReal(0.3)])),
      _malformed(),
    );
  });

  test('BacnetColorCommand fade to color matches bacnet-stack', () {
    const command = BacnetColorCommand(
      operation: BacnetColorOperation.fadeToColor,
      targetColor: BacnetXYColor(0.5, 0.25),
      fadeTime: Duration(milliseconds: 1500),
    );
    // [0] enum, [1] {REAL REAL}, [3] Unsigned
    expect(
      _encoded(command.toValue()),
      '09 01 1e 44 3f 00 00 00 44 3e 80 00 00 1f 3a 05 dc',
    );
    expect(BacnetColorCommand.fromValue(_wire(command.toValue())), command);
  });

  test('BacnetColorCommand fade to color temperature matches bacnet-stack', () {
    const command = BacnetColorCommand(
      operation: BacnetColorOperation.fadeToColorTemperature,
      targetColorTemperature: 3000,
      fadeTime: Duration(seconds: 1),
    );
    // [0] enum, [2] Unsigned, [3] Unsigned
    expect(_encoded(command.toValue()), '09 02 2a 0b b8 3a 03 e8');
    expect(BacnetColorCommand.fromValue(_wire(command.toValue())), command);
  });

  test('BacnetColorCommand ramp and step round-trip', () {
    const ramp = BacnetColorCommand(
      operation: BacnetColorOperation.rampToColorTemperature,
      targetColorTemperature: 4000,
      rampRate: 500,
    );
    const step = BacnetColorCommand(
      operation: BacnetColorOperation.stepUpColorTemperature,
      stepIncrement: 100,
    );
    expect(BacnetColorCommand.fromValue(_wire(ramp.toValue())), ramp);
    expect(BacnetColorCommand.fromValue(_wire(step.toValue())), step);
  });

  test('operations expose readable labels', () {
    expect(BacnetLightingOperation.fadeTo.label, 'Fade To');
    expect(BacnetColorOperation.fadeToColor.label, 'Fade To Color');
    expect(const BacnetLightingOperation(999).label, 'Lighting Operation 999');
  });
}
