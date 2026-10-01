import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

void main() {
  // The checks run before the stack is used, so no start() is needed.
  final client = BacnetClient();

  test('invalid requests fail the returned future', () async {
    const spec = BacnetReadAccessSpecification(
      objectIdentifier: BacnetObject(
        type: BacnetObjectType.analogValue,
        instance: 1,
      ),
      properties: [
        BacnetPropertyReference(
          propertyIdentifier: BacnetPropertyId.presentValue,
        ),
      ],
    );
    final duplicate = client.readMultiple(1, const [spec, spec]);
    await expectLater(duplicate, throwsArgumentError);

    final invalidObject = client.writeProperty(
      1,
      const BacnetObjectType(1024),
      1,
      BacnetPropertyId.presentValue,
      const BacnetReal(1),
    );
    await expectLater(invalidObject, throwsA(isA<BacnetEncodeException>()));

    expect(await client.readMultiple(1, const []), isEmpty);
  });
}
