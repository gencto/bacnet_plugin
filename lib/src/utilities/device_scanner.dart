/// @docImport '../core/bacnet_config.dart';
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../client/bacnet_client.dart';
import '../constants/enumerations.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import '../core/types.dart';
import '../models/bacnet_object.dart';
import '../models/device_metadata.dart';
import '../models/discovered_device.dart';
import '../models/events.dart';
import '../models/rpm_models.dart';

/// Runs [action] for every item with at most [concurrency] actions pending.
Future<List<R>> mapConcurrent<T, R>(
  Iterable<T> items,
  int concurrency,
  Future<R> Function(T item) action,
) async {
  final list = items.toList(growable: false);
  final results = List<R?>.filled(list.length, null);
  var next = 0;
  Future<void> lane() async {
    while (next < list.length) {
      final index = next++;
      results[index] = await action(list[index]);
    }
  }

  await Future.wait([
    for (var i = 0; i < concurrency && i < list.length; i++) lane(),
  ]);
  return results.cast<R>();
}

const _summaryProperties = [
  BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.objectName),
  BacnetPropertyReference(
    propertyIdentifier: BacnetPropertyId.vendorIdentifier,
  ),
  BacnetPropertyReference(
    propertyIdentifier: BacnetPropertyId.maxApduLengthAccepted,
  ),
  BacnetPropertyReference(
    propertyIdentifier: BacnetPropertyId.segmentationSupported,
  ),
  BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.modelName),
  BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.vendorName),
  BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.description),
];

const _detailProperties = [
  ..._summaryProperties,
  BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.location),
  BacnetPropertyReference(
    propertyIdentifier: BacnetPropertyId.firmwareRevision,
  ),
  BacnetPropertyReference(
    propertyIdentifier: BacnetPropertyId.applicationSoftwareVersion,
  ),
  BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.protocolVersion),
  BacnetPropertyReference(
    propertyIdentifier: BacnetPropertyId.protocolRevision,
  ),
];

/// High-level utility for discovering and scanning BACnet devices.
///
/// Discovery and scans run many requests in parallel (bounded by
/// [concurrency]); the client's scheduler keeps the per-device load within
/// [BacnetConfig.maxConcurrentRequestsPerDevice].
///
/// ```dart
/// final scanner = DeviceScanner(client);
/// final devices = await scanner.discoverDevices(
///   timeout: const Duration(seconds: 5),
/// );
/// ```
@immutable
class DeviceScanner {
  /// Creates a device scanner using the provided BACnet client.
  const DeviceScanner(
    this.client, {
    this.concurrency = 32,
    this.background = true,
  });

  /// The BACnet client used for communication.
  final BacnetClient client;

  /// Maximum number of devices or batches processed in parallel.
  final int concurrency;

  /// Send the scan requests as background requests, so that interactive
  /// requests of the application overtake a running scan.
  final bool background;

  /// Discovers devices on the network.
  ///
  /// Sends a Who-Is and collects I-Am answers for [timeout], then reads the
  /// identification properties of every device in parallel. Set
  /// [readDetails] to false to skip the property reads (fast inventory of
  /// very large networks). Returns the devices sorted by device instance.
  Future<List<DiscoveredDevice>> discoverDevices({
    Duration timeout = const Duration(seconds: 10),
    int? lowLimit,
    int? highLimit,
    bool readDetails = true,
  }) async {
    final announcements = <int, IAmEvent>{};
    final subscription = client.events.listen((event) {
      if (event is IAmEvent) {
        announcements[event.deviceId] = event;
      }
    });

    try {
      await client.sendWhoIs(
        lowLimit: lowLimit ?? -1,
        highLimit: highLimit ?? -1,
      );
      await Future<void>.delayed(timeout);
    } finally {
      await subscription.cancel();
    }

    final devices = await mapConcurrent(
      announcements.values,
      concurrency,
      (announcement) => readDetails
          ? _describe(announcement)
          : Future.value(_fromAnnouncement(announcement)),
    );
    devices.sort((a, b) => a.deviceId.compareTo(b.deviceId));
    return devices;
  }

  DiscoveredDevice _fromAnnouncement(IAmEvent announcement) {
    return DiscoveredDevice(
      deviceId: announcement.deviceId,
      vendorId: announcement.vendorId,
      maxApduLength: announcement.maxApdu,
      segmentationSupported: announcement.segmentation,
      ipAddress: announcement.ipAddress,
      port: announcement.port,
      networkNumber: announcement.net,
    );
  }

  Future<DiscoveredDevice> _describe(IAmEvent announcement) async {
    final basic = _fromAnnouncement(announcement);
    try {
      final props = await _readDeviceProperties(
        announcement.deviceId,
        _summaryProperties,
      );
      if (props == null) {
        return basic.copyWith(
          deviceName:
              'Device ${announcement.deviceId} (IP: ${announcement.ipAddress})',
        );
      }
      return _merge(basic, props);
    } on BacnetException catch (e) {
      client.log(
        BacnetLogLevel.debug,
        'device ${announcement.deviceId}: identification failed',
        e,
      );
      return basic.copyWith(
        deviceName:
            'Device ${announcement.deviceId} (IP: ${announcement.ipAddress})',
      );
    }
  }

  Future<Map<int, dynamic>?> _readDeviceProperties(
    int deviceId,
    List<BacnetPropertyReference> properties,
  ) async {
    final results = await client
        .readMultiple(deviceId, background: background, [
          BacnetReadAccessSpecification(
            objectIdentifier: BacnetObject(
              type: BacnetObjectType.device,
              instance: deviceId,
            ),
            properties: properties,
          ),
        ]);
    return results['${BacnetObjectType.device}:$deviceId'];
  }

  static T? _value<T>(Map<int, dynamic> props, int propertyId) {
    final value = props[propertyId];
    return value is T ? value : null;
  }

  DiscoveredDevice _merge(DiscoveredDevice device, Map<int, dynamic> props) {
    return device.copyWith(
      vendorId: _value<int>(props, BacnetPropertyId.vendorIdentifier),
      maxApduLength: _value<int>(props, BacnetPropertyId.maxApduLengthAccepted),
      segmentationSupported: switch (_value<int>(
        props,
        BacnetPropertyId.segmentationSupported,
      )) {
        final int value => BacnetSegmentation(value),
        null => null,
      },
      deviceName: _value<String>(props, BacnetPropertyId.objectName),
      description: _value<String>(props, BacnetPropertyId.description),
      location: _value<String>(props, BacnetPropertyId.location),
      modelName: _value<String>(props, BacnetPropertyId.modelName),
      vendorName: _value<String>(props, BacnetPropertyId.vendorName),
      firmwareRevision: _value<String>(
        props,
        BacnetPropertyId.firmwareRevision,
      ),
      applicationSoftwareVersion: _value<String>(
        props,
        BacnetPropertyId.applicationSoftwareVersion,
      ),
      protocolVersion: _value<int>(props, BacnetPropertyId.protocolVersion),
      protocolRevision: _value<int>(props, BacnetPropertyId.protocolRevision),
    );
  }

  /// Gets detailed identification of a device using ReadPropertyMultiple.
  ///
  /// Throws a [BacnetException] if the device does not respond.
  Future<DiscoveredDevice> getDeviceDetails(int deviceId) async {
    final props = await _readDeviceProperties(deviceId, _detailProperties);
    if (props == null) {
      throw BacnetException('No response from device $deviceId');
    }
    return _merge(
      DiscoveredDevice(
        deviceId: deviceId,
        vendorId: 0,
        maxApduLength: 480,
        segmentationSupported: BacnetSegmentation.none,
      ),
      props,
    );
  }

  /// Scans a device's objects and their properties.
  ///
  /// Reads the object list and, when [propertyIds] are given, those
  /// properties of up to [maxObjects] objects with ReadPropertyMultiple
  /// batches of [batchSize] objects (batches run in parallel and are split
  /// automatically when an answer exceeds the device's APDU size).
  Future<Map<BacnetObject, Map<int, dynamic>>> scanDevice(
    int deviceId, {
    List<BacnetPropertyId>? propertyIds,
    int maxObjects = 100,
    int batchSize = 20,
  }) async {
    final objects = await client.scanDevice(deviceId, background: background);
    final targets = objects.length > maxObjects
        ? objects.sublist(0, maxObjects)
        : objects;
    final results = <BacnetObject, Map<int, dynamic>>{
      for (final object in targets) object: <int, dynamic>{},
    };
    if (propertyIds == null || propertyIds.isEmpty) {
      return results;
    }

    final batches = [
      for (var i = 0; i < targets.length; i += batchSize)
        targets.sublist(
          i,
          i + batchSize < targets.length ? i + batchSize : targets.length,
        ),
    ];
    await mapConcurrent(batches, concurrency, (batch) async {
      final specs = [
        for (final object in batch)
          BacnetReadAccessSpecification(
            objectIdentifier: object,
            properties: [
              for (final id in propertyIds)
                BacnetPropertyReference(propertyIdentifier: id),
            ],
          ),
      ];
      try {
        final batchResults = await client.readMultiple(
          deviceId,
          specs,
          background: background,
        );
        for (final entry in batchResults.entries) {
          final parts = entry.key.split(':');
          if (parts.length != 2) continue;
          final type = int.tryParse(parts[0]);
          final instance = int.tryParse(parts[1]);
          if (type == null || instance == null) continue;
          final object = BacnetObject(
            type: BacnetObjectType(type),
            instance: instance,
          );
          if (results.containsKey(object)) {
            results[object] = entry.value;
          }
        }
      } on BacnetException catch (e, st) {
        client.log(
          BacnetLogLevel.warning,
          'Failed to scan batch of objects for device $deviceId',
          e,
          st,
        );
      }
    });
    return results;
  }

  /// Gets metadata of a device including its object list.
  Future<DeviceMetadata> getDeviceMetadata(
    int deviceId, {
    int maxObjects = 100,
  }) async {
    final objects = await client.scanDevice(deviceId, background: background);
    return DeviceMetadata(
      deviceId: deviceId,
      objectCount: objects.length,
      objects: objects.length > maxObjects
          ? objects.sublist(0, maxObjects)
          : objects,
    );
  }
}
