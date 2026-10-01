import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/client/read_coalescer.dart';
import 'package:test/test.dart';

/// Analog Value [instance].
BacnetObject av(int instance) =>
    BacnetObject(type: BacnetObjectType.analogValue, instance: instance);

/// Records requests and answers them from [values] or with scripted
/// failures.
final class FakeDevice {
  final Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>> values =
      {};
  final List<(int, BacnetObjectType, int, BacnetPropertyId)> singles = [];
  final List<List<BacnetReadAccessSpecification>> multiples = [];
  BacnetException? multipleError;
  int backgroundRequests = 0;

  BacnetPropertyResult _result(BacnetObject object, BacnetPropertyId id) =>
      values[object]?[id] ??
      const BacnetError(
        BacnetErrorClass.property,
        BacnetErrorCode.unknownProperty,
      );

  Future<BacnetValue> readProperty(
    int deviceId,
    BacnetObjectType type,
    int instance,
    BacnetPropertyId property,
    Duration? timeout, {
    bool background = false,
  }) async {
    singles.add((deviceId, type, instance, property));
    switch (_result(BacnetObject(type: type, instance: instance), property)) {
      case final BacnetValue value:
        return value;
      case BacnetError(:final errorClass, :final errorCode):
        throw BacnetProtocolException(
          'device $deviceId returned an error',
          errorClass: errorClass,
          errorCode: errorCode,
        );
    }
  }

  Future<Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>>
  readMultiple(
    int deviceId,
    List<BacnetReadAccessSpecification> specs,
    Duration? timeout, {
    bool background = false,
  }) async {
    multiples.add(specs);
    if (background) backgroundRequests++;
    if (multipleError case final error?) throw error;
    return {
      for (final spec in specs)
        spec.objectIdentifier: {
          for (final p in spec.properties)
            p.propertyIdentifier: _result(
              spec.objectIdentifier,
              p.propertyIdentifier,
            ),
        },
    };
  }
}

BacnetReal real(num value) => BacnetReal(value.toDouble());

void main() {
  late FakeDevice device;
  late ReadCoalescer coalescer;

  ReadCoalescer create({int maxBatchSize = 24}) => ReadCoalescer(
    readProperty: device.readProperty,
    readMultiple: device.readMultiple,
    maxBatchSize: maxBatchSize,
  );

  Future<BacnetValue> read(int instance, BacnetPropertyId property) =>
      coalescer.read(1, BacnetObjectType.analogValue, instance, property);

  setUp(() {
    device = FakeDevice();
    for (var i = 0; i < 100; i++) {
      device.values[av(i)] = {
        BacnetPropertyId.presentValue: real(i),
        BacnetPropertyId.objectName: BacnetCharacterString('AV-$i'),
      };
    }
    coalescer = create();
  });

  test('merges concurrent reads into one ReadPropertyMultiple', () async {
    final values = await Future.wait([
      read(1, BacnetPropertyId.presentValue),
      read(1, BacnetPropertyId.objectName),
      read(2, BacnetPropertyId.presentValue),
    ]);
    expect(values, [real(1), const BacnetCharacterString('AV-1'), real(2)]);
    expect(device.singles, isEmpty);
    expect(device.multiples, hasLength(1));
    expect(device.multiples.single, hasLength(2), reason: 'grouped by object');
  });

  test('sends a lone read as ReadProperty', () async {
    expect(await read(5, BacnetPropertyId.presentValue), real(5));
    expect(device.multiples, isEmpty);
    expect(device.singles, hasLength(1));
  });

  test('shares the result of identical reads', () async {
    final values = await Future.wait([
      read(3, BacnetPropertyId.presentValue),
      read(3, BacnetPropertyId.presentValue),
      read(4, BacnetPropertyId.presentValue),
    ]);
    expect(values, [real(3), real(3), real(4)]);
    final properties = device.multiples.single.expand((s) => s.properties);
    expect(properties, hasLength(2));
  });

  test('splits batches at maxBatchSize', () async {
    coalescer = create(maxBatchSize: 10);
    final values = await Future.wait([
      for (var i = 0; i < 25; i++) read(i, BacnetPropertyId.presentValue),
    ]);
    expect(values, [for (var i = 0; i < 25; i++) real(i)]);
    expect(device.multiples.map((m) => m.length), [10, 10, 5]);
  });

  test('keeps devices apart', () async {
    await Future.wait([
      coalescer.read(
        1,
        BacnetObjectType.analogValue,
        1,
        BacnetPropertyId.presentValue,
      ),
      coalescer.read(
        2,
        BacnetObjectType.analogValue,
        1,
        BacnetPropertyId.presentValue,
      ),
    ]);
    expect(device.singles.map((s) => s.$1), unorderedEquals([1, 2]));
  });

  test('fails only reads with property access errors', () async {
    device.values[av(7)]![BacnetPropertyId.description] = const BacnetError(
      BacnetErrorClass.property,
      BacnetErrorCode.unknownProperty,
    );
    final ok = read(7, BacnetPropertyId.presentValue);
    final failing = read(7, BacnetPropertyId.description);
    expect(await ok, real(7));
    await expectLater(
      failing,
      throwsA(
        isA<BacnetProtocolException>().having(
          (e) => e.errorCode,
          'errorCode',
          BacnetErrorCode.unknownProperty,
        ),
      ),
    );
    expect(device.singles, isEmpty);
  });

  test('falls back to single reads and remembers rejecting devices', () async {
    device.multipleError = const BacnetRejectException(
      'rejected',
      reason: BacnetRejectReason.unrecognizedService,
    );
    final values = await Future.wait([
      read(1, BacnetPropertyId.presentValue),
      read(2, BacnetPropertyId.presentValue),
    ]);
    expect(values, [real(1), real(2)]);
    expect(device.singles, hasLength(2));
    expect(coalescer.devicesWithoutMultiple, [1]);

    await Future.wait([
      read(3, BacnetPropertyId.presentValue),
      read(4, BacnetPropertyId.presentValue),
    ]);
    expect(device.multiples, hasLength(1), reason: 'no second attempt');
  });

  test('retries other failures with single reads', () async {
    device.multipleError = const BacnetAbortException(
      'aborted',
      reason: BacnetAbortReason.other,
    );
    final values = await Future.wait([
      read(1, BacnetPropertyId.presentValue),
      read(2, BacnetPropertyId.presentValue),
    ]);
    expect(values, [real(1), real(2)]);
    expect(coalescer.devicesWithoutMultiple, isEmpty);
  });

  test('fails the reads when the request fails unexpectedly', () async {
    coalescer = ReadCoalescer(
      readProperty: device.readProperty,
      readMultiple: (id, specs, timeout, {background = false}) =>
          Future.error(StateError('broken')),
    );
    final reads = [
      read(1, BacnetPropertyId.presentValue),
      read(2, BacnetPropertyId.presentValue),
    ];
    for (final future in reads) {
      await expectLater(future, throwsStateError);
    }
    expect(device.singles, isEmpty);
  });

  test('does not retry when the device is unreachable', () async {
    device.multipleError = const BacnetTimeoutException('no answer');
    final reads = [
      read(1, BacnetPropertyId.presentValue),
      read(2, BacnetPropertyId.presentValue),
    ];
    for (final future in reads) {
      await expectLater(future, throwsA(isA<BacnetTimeoutException>()));
    }
    expect(device.singles, isEmpty);
  });

  test('reads properties the device left out of the answer', () async {
    final original = device.readMultiple;
    coalescer = ReadCoalescer(
      readProperty: device.readProperty,
      readMultiple: (id, specs, timeout, {background = false}) async {
        final result = await original(id, specs, timeout);
        result[av(9)]!.remove(BacnetPropertyId.objectName);
        return result;
      },
    );
    final values = await Future.wait([
      read(9, BacnetPropertyId.presentValue),
      read(9, BacnetPropertyId.objectName),
    ]);
    expect(values, [real(9), const BacnetCharacterString('AV-9')]);
    expect(device.singles, hasLength(1));
  });

  test('keeps background reads in separate batches', () async {
    await Future.wait([
      read(1, BacnetPropertyId.presentValue),
      read(2, BacnetPropertyId.presentValue),
      coalescer.read(
        1,
        BacnetObjectType.analogValue,
        3,
        BacnetPropertyId.presentValue,
        background: true,
      ),
      coalescer.read(
        1,
        BacnetObjectType.analogValue,
        4,
        BacnetPropertyId.presentValue,
        background: true,
      ),
    ]);
    expect(device.multiples, hasLength(2));
    expect(device.backgroundRequests, 1);
  });

  test('batches reads issued within the window', () async {
    coalescer = ReadCoalescer(
      readProperty: device.readProperty,
      readMultiple: device.readMultiple,
      window: const Duration(milliseconds: 20),
    );
    final first = read(1, BacnetPropertyId.presentValue);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = read(2, BacnetPropertyId.presentValue);
    expect(await Future.wait([first, second]), [real(1), real(2)]);
    expect(device.multiples, hasLength(1));
  });
}
