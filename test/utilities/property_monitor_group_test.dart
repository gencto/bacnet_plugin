import 'dart:async';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/testing.dart';
import 'package:test/test.dart';

void main() {
  const sensor = BacnetObject(type: BacnetObjectType.analogInput, instance: 1);
  const output = BacnetObject(type: BacnetObjectType.analogOutput, instance: 1);
  const missing = BacnetObject(
    type: BacnetObjectType.analogValue,
    instance: 99,
  );

  late FakeBacnetDevice ahu;
  late FakeBacnetClient client;

  setUp(() async {
    ahu = FakeBacnetDevice(1234)
      ..addObject(
        BacnetObjectType.analogInput,
        1,
        presentValue: const BacnetReal(20),
      )
      ..addObject(
        BacnetObjectType.analogOutput,
        1,
        presentValue: const BacnetReal(50),
      );
    client = FakeBacnetClient(devices: [ahu]);
    await client.start();
  });

  tearDown(() => client.close());

  Iterable<FakeBacnetRequest> requests(String service) =>
      client.requests.where((r) => r.service == service);

  /// The properties of the SubscribeCOVPropertyMultiple requests.
  Set<(BacnetObject, BacnetPropertyId)> multipleSubscribed() => {
    for (final request in requests('subscribeCOVPropertyMultiple'))
      for (final specification
          in request.arguments['specifications']!
              as List<BacnetCovSubscriptionSpecification>)
        for (final reference in specification.references)
          (specification.object, reference.property),
  };

  /// Retries [check] until it passes: the fake devices answer after their
  /// latency and slow CI runners take their time.
  Future<void> eventually(void Function() check) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        check();
        return;
      } on TestFailure {
        if (DateTime.now().isAfter(deadline)) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void set(BacnetObject object, double value) =>
      ahu.object(object.type, object.instance)![BacnetPropertyId.presentValue] =
          BacnetReal(value);

  test('reads the services the fake device executes', () async {
    final services = await client.read(
      1234,
      const BacnetObject(type: BacnetObjectType.device, instance: 1234),
      BacnetProperties.protocolServicesSupported,
    );
    expect(services, contains(BacnetServiceSupported.readPropertyMultiple));
    expect(
      services,
      contains(BacnetServiceSupported.subscribeCovPropertyMultiple),
    );
    ahu.unsupportedServices.add(BacnetConfirmedService.readPropertyMultiple);
    expect(
      await client.read(
        1234,
        const BacnetObject(type: BacnetObjectType.device, instance: 1234),
        BacnetProperties.protocolServicesSupported,
      ),
      isNot(contains(BacnetServiceSupported.readPropertyMultiple)),
    );
  });

  test('shares one subscription between the properties of a device', () async {
    final monitor = PropertyMonitor(client);
    final values = <(BacnetObject, BacnetValue)>[];
    final listeners = [
      for (final object in [sensor, output])
        monitor.monitorPresentValue(1234, object).listen((update) {
          if (update case PropertyValueUpdate(
            :final value,
            source: UpdateSource.cov,
          )) {
            values.add((object, value));
          }
        }),
    ];
    await eventually(
      () => expect(multipleSubscribed(), {
        (sensor, BacnetPropertyId.presentValue),
        (output, BacnetPropertyId.presentValue),
      }),
    );
    expect(requests('subscribeCOV'), isEmpty);
    final processIds = {
      for (final r in requests('subscribeCOVPropertyMultiple'))
        r.arguments['processId'],
    };
    expect(processIds, hasLength(1));

    // the fake device takes the subscription after its latency: change the
    // values until both notifications arrive
    await eventually(() {
      set(sensor, 21);
      set(output, 60);
      expect(
        values,
        containsAll([
          (sensor, const BacnetReal(21)),
          (output, const BacnetReal(60)),
        ]),
      );
    });

    await listeners.first.cancel();
    await eventually(
      () => expect(requests('unsubscribeCOVPropertyMultiple'), hasLength(1)),
    );
    final cancel = requests('unsubscribeCOVPropertyMultiple').single;
    expect(
      (cancel.arguments['specifications']!
              as List<BacnetCovSubscriptionSpecification>)
          .single
          .object,
      sensor,
    );
    await eventually(() {
      set(output, 61);
      expect(values, contains((output, const BacnetReal(61))));
    });
    await listeners.last.cancel();
  });

  test('subscribes refused properties alone', () async {
    final monitor = PropertyMonitor(client);
    final listeners = [
      for (final object in [sensor, missing])
        monitor
            .monitor(
              deviceId: 1234,
              object: object,
              propertyId: BacnetPropertyId.presentValue,
              pollingInterval: const Duration(milliseconds: 10),
            )
            .listen((_) {}),
    ];
    // the device named the missing object; the sensor stayed shared
    await eventually(
      () => expect(
        requests('subscribeCOV').map((request) => request.object),
        contains(missing),
      ),
    );
    expect(
      multipleSubscribed(),
      contains((sensor, BacnetPropertyId.presentValue)),
    );
    expect(
      requests('subscribeCOVPropertyMultiple').last.arguments['specifications'],
      [
        BacnetCovSubscriptionSpecification(sensor, const [
          BacnetCovReference(BacnetPropertyId.presentValue),
        ]),
      ],
    );
    expect(requests('subscribeCOV').single.object, missing);
    for (final listener in listeners) {
      await listener.cancel();
    }
  });

  test('uses SubscribeCOV with devices without the service', () async {
    ahu.unsupportedServices.add(
      BacnetConfirmedService.subscribeCovPropertyMultiple,
    );
    final monitor = PropertyMonitor(client);
    final listener = monitor.monitorPresentValue(1234, sensor).listen((_) {});
    await eventually(
      () => expect(requests('subscribeCOV').map((r) => r.object), [sensor]),
    );
    expect(requests('subscribeCOVPropertyMultiple'), isEmpty);
    await listener.cancel();
  });

  test('can be told not to share subscriptions', () async {
    final monitor = PropertyMonitor(client, useCovMultiple: false);
    final listener = monitor.monitorPresentValue(1234, sensor).listen((_) {});
    await eventually(() => expect(requests('subscribeCOV'), hasLength(1)));
    expect(requests('subscribeCOVPropertyMultiple'), isEmpty);
    await listener.cancel();
  });

  test('renews the shared subscription', () async {
    final monitor = PropertyMonitor(
      client,
      subscriptionLifetime: const Duration(milliseconds: 40),
    );
    final listener = monitor.monitorPresentValue(1234, sensor).listen((_) {});
    await eventually(
      () => expect(
        requests('subscribeCOVPropertyMultiple').length,
        greaterThanOrEqualTo(3),
      ),
    );
    await listener.cancel();
    // no renewals once the subscription is cancelled
    await eventually(
      () => expect(requests('unsubscribeCOVPropertyMultiple'), isNotEmpty),
    );
    final count = requests('subscribeCOVPropertyMultiple').length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(requests('subscribeCOVPropertyMultiple'), hasLength(count));
  });
}
