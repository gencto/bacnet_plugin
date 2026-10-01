import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

void main() {
  test('properties decode their datatype', () {
    expect(
      BacnetProperties.objectName.decode(const BacnetCharacterString('AHU')),
      'AHU',
    );
    expect(
      BacnetProperties.units.decode(const BacnetEnumerated(62)),
      BacnetEngineeringUnits.degreesCelsius,
    );
    expect(
      BacnetProperties.binaryPresentValue.decode(const BacnetEnumerated(1)),
      BacnetBinaryPV.active,
    );
    expect(
      BacnetProperties.statusFlags.decode(
        const BacnetBitString([false, true, false, false]),
      ),
      const BacnetStatusFlags(fault: true),
    );
    expect(
      BacnetProperties.objectList.decode(
        const BacnetObject(type: BacnetObjectType.device, instance: 1),
      ),
      [const BacnetObject(type: BacnetObjectType.device, instance: 1)],
      reason: 'a one-element array arrives as a single value',
    );
    expect(
      BacnetProperties.propertyList.decode(
        const BacnetList([BacnetEnumerated(85), BacnetEnumerated(77)]),
      ),
      [BacnetPropertyId.presentValue, BacnetPropertyId.objectName],
    );
  });

  test('another datatype throws a BacnetDecodeException', () {
    expect(
      () => BacnetProperties.analogPresentValue.decode(const BacnetUnsigned(1)),
      throwsA(isA<BacnetDecodeException>()),
    );
    expect(
      () => BacnetProperties.units.decode(const BacnetUnsigned(62)),
      throwsA(isA<BacnetDecodeException>()),
    );
  });

  test('writable properties encode their datatype', () {
    expect(
      BacnetProperties.analogPresentValue.encode(21.5),
      const BacnetReal(21.5),
    );
    expect(
      BacnetProperties.binaryPresentValue.encode(BacnetBinaryPV.active),
      const BacnetEnumerated(1),
    );
    expect(
      BacnetProperties.stateText.encode(['Off', 'On']),
      const BacnetList([
        BacnetCharacterString('Off'),
        BacnetCharacterString('On'),
      ]),
    );
  });

  test('custom properties have exact types', () {
    final offset = BacnetWritableProperty.real(const BacnetPropertyId(512));
    final BacnetWritableProperty<double> typed = offset;
    expect(typed.encode(1.5), const BacnetReal(1.5));
    final counter = BacnetProperty.unsigned(const BacnetPropertyId(513));
    expect(counter.decode(const BacnetUnsigned(7)), 7);
    expect(counter, isNot(isA<BacnetWritableProperty<int>>()));
  });

  test('get reads results of readMultiple leniently', () {
    const results = <BacnetPropertyId, BacnetPropertyResult>{
      BacnetPropertyId.objectName: BacnetCharacterString('AHU'),
      BacnetPropertyId.units: BacnetUnsigned(62), // wrong datatype
      BacnetPropertyId.description: BacnetError(
        BacnetErrorClass.property,
        BacnetErrorCode.unknownProperty,
      ),
    };
    expect(results.get(BacnetProperties.objectName), 'AHU');
    expect(results.get(BacnetProperties.units), isNull);
    expect(results.get(BacnetProperties.description), isNull);
    expect(results.get(BacnetProperties.location), isNull);
  });

  test('encodeValue accepts what generic writes infer', () {
    // write<T>(property, value) infers T = num for a double property and
    // an int literal; encode cannot be read through that view
    BacnetValue write<T>(BacnetWritableProperty<T> property, T value) =>
        property.encodeValue(value);

    expect(
      write(BacnetProperties.analogPresentValue, 35),
      const BacnetReal(35),
    );
    expect(
      write(BacnetProperties.analogPresentValue, 21.5),
      const BacnetReal(21.5),
    );
    expect(
      () => write(BacnetProperties.notificationClass, 1.5),
      throwsArgumentError,
    );
    expect(
      () => write<Object>(BacnetProperties.objectName, 3),
      throwsArgumentError,
    );
  });
}
