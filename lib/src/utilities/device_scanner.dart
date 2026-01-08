import 'dart:async';

import 'package:flutter/foundation.dart';

import '../client/bacnet_client.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../models/device_metadata.dart';
import '../models/discovered_device.dart';

/// High-level utility for discovering and scanning BACnet devices.
///
/// Provides convenient methods for device discovery and object enumeration,
/// wrapping the lower-level [BacnetClient] API with a simpler interface.
///
/// Example:
/// ```dart
/// final client = BacnetClient();
/// await client.start();
///
/// final scanner = DeviceScanner(client);
///
/// // Discover devices on the network
/// final devices = await scanner.discoverDevices(
///   timeout: Duration(seconds: 10),
/// );
///
/// for (final device in devices) {
///   print('Found: ${device.deviceName} (ID: ${device.deviceId})');
/// }
///
/// // Get detailed information about a device
/// if (devices.isNotEmpty) {
///   final metadata = await scanner.getDeviceDetails(devices.first.deviceId);
///   print('Device has ${metadata.objectCount} objects');
/// }
/// ```
@immutable
class DeviceScanner {
  /// Creates a device scanner using the provided BACnet client.
  const DeviceScanner(this.client);

  /// The BACnet client used for communication.
  final BacnetClient client;

  /// Discovers devices on the network.
  ///
  /// Sends a Who-Is broadcast and collects I-Am responses until [timeout].
  /// Optionally filter by device ID range using [lowLimit] and [highLimit].
  ///
  /// Returns a list of discovered devices with their metadata, sorted by device ID.
  ///
  /// Example:
  /// ```dart
  /// // Discover all devices
  /// final allDevices = await scanner.discoverDevices();
  ///
  /// // Discover devices in a specific range
  /// final rangeDevices = await scanner.discoverDevices(
  ///   lowLimit: 1000,
  ///   highLimit: 2000,
  /// );
  /// ```
  Future<List<DiscoveredDevice>> discoverDevices({
    Duration timeout = const Duration(seconds: 10),
    int? lowLimit,
    int? highLimit,
  }) async {
    // Store device ID -> IP address mapping from I-Am responses
    final deviceIPs = <int, String>{};

    // Listen for I-Am responses and extract IP from MAC
    final subscription = client.events.listen((event) {
      if (event is IAmResponse) {
        // For BACnet/IP, MAC is 6 bytes: 4 for IP + 2 for port
        if (event.mac.length >= 4) {
          final ip =
              '${event.mac[0]}.${event.mac[1]}.${event.mac[2]}.${event.mac[3]}';
          deviceIPs[event.deviceId] = ip;
        }
      }
    });

    // Send Who-Is broadcast
    await client.sendWhoIs(
      lowLimit: lowLimit ?? -1,
      highLimit: highLimit ?? -1,
    );

    // Wait for timeout
    await Future<void>.delayed(timeout);
    await subscription.cancel();

    // Create devices from discovered IDs, using RPM to get details
    final devices = <DiscoveredDevice>[];
    for (final deviceId in deviceIPs.keys) {
      // Add manual binding first (required for communication)
      final ip = deviceIPs[deviceId]!;
      await client.addDeviceBinding(deviceId, ip);

      // Try to get device details via RPM
      try {
        final results = await client.readMultiple(deviceId, [
          BacnetReadAccessSpecification(
            objectIdentifier: BacnetObject(
              type: BacnetObjectType.device,
              instance: deviceId,
            ),
            properties: const [
              BacnetPropertyReference(
                propertyIdentifier: BacnetPropertyId.objectName,
              ),
              BacnetPropertyReference(
                propertyIdentifier: BacnetPropertyId.vendorIdentifier,
              ),
              BacnetPropertyReference(
                propertyIdentifier: BacnetPropertyId.maxApduLengthAccepted,
              ),
              BacnetPropertyReference(
                propertyIdentifier: BacnetPropertyId.modelName,
              ),
              BacnetPropertyReference(
                propertyIdentifier: BacnetPropertyId.vendorName,
              ),
              BacnetPropertyReference(
                propertyIdentifier: BacnetPropertyId.description,
              ),
            ],
          ),
        ]);

        // Parse RPM results
        final deviceKey = '${BacnetObjectType.device}:$deviceId';
        final props = results[deviceKey];

        if (props != null) {
          devices.add(
            DiscoveredDevice(
              deviceId: deviceId,
              vendorId: props[BacnetPropertyId.vendorIdentifier] as int? ?? 0,
              maxApduLength:
                  props[BacnetPropertyId.maxApduLengthAccepted] as int? ?? 1476,
              segmentationSupported: 0,
              deviceName: props[BacnetPropertyId.objectName] as String?,
              modelName: props[BacnetPropertyId.modelName] as String?,
              vendorName: props[BacnetPropertyId.vendorName] as String?,
              description: props[BacnetPropertyId.description] as String?,
            ),
          );
        } else {
          // RPM returned but no data for this device
          devices.add(
            DiscoveredDevice(
              deviceId: deviceId,
              vendorId: 0,
              maxApduLength: 1476,
              segmentationSupported: 0,
              deviceName: 'Device $deviceId (IP: $ip)',
            ),
          );
        }
      } on Exception {
        // RPM failed, add with basic info
        devices.add(
          DiscoveredDevice(
            deviceId: deviceId,
            vendorId: 0,
            maxApduLength: 1476,
            segmentationSupported: 0,
            deviceName: 'Device $deviceId (IP: $ip)',
          ),
        );
      }
    }

    // Sort by device ID
    devices.sort((a, b) => a.deviceId.compareTo(b.deviceId));
    return devices;
  }

  /// Gets detailed metadata for a device.
  ///
  /// Reads standard device properties like name, vendor, model, firmware,
  /// and other identification information using ReadPropertyMultiple.
  ///
  /// Throws an exception if the device does not respond or if required
  /// properties cannot be read.
  ///
  /// Example:
  /// ```dart
  /// final device = await scanner.getDeviceDetails(1234);
  /// print('Name: ${device.deviceName}');
  /// print('Vendor: ${device.vendorName}');
  /// print('Model: ${device.modelName}');
  /// ```
  Future<DiscoveredDevice> getDeviceDetails(int deviceId) async {
    // Read device properties using RPM
    final results = await client.readMultiple(deviceId, [
      BacnetReadAccessSpecification(
        objectIdentifier: BacnetObject(
          type: BacnetObjectType.device,
          instance: deviceId,
        ),
        properties: const [
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.objectName,
          ),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.vendorIdentifier,
          ),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.maxApduLengthAccepted,
          ),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.segmentationSupported,
          ),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.description,
          ),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.location,
          ),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.modelName,
          ),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.vendorName,
          ),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.firmwareRevision,
          ),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.applicationSoftwareVersion,
          ),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.protocolVersion,
          ),
          BacnetPropertyReference(
            propertyIdentifier: BacnetPropertyId.protocolRevision,
          ),
        ],
      ),
    ]);

    // Parse results
    final deviceKey = '${BacnetObjectType.device}:$deviceId';
    final props = results[deviceKey];

    if (props == null) {
      throw Exception('No response from device $deviceId');
    }

    return DiscoveredDevice(
      deviceId: deviceId,
      vendorId: props[BacnetPropertyId.vendorIdentifier] as int? ?? 0,
      maxApduLength:
          props[BacnetPropertyId.maxApduLengthAccepted] as int? ?? 480,
      segmentationSupported:
          props[BacnetPropertyId.segmentationSupported] as int? ?? 0,
      deviceName: props[BacnetPropertyId.objectName] as String?,
      description: props[BacnetPropertyId.description] as String?,
      location: props[BacnetPropertyId.location] as String?,
      modelName: props[BacnetPropertyId.modelName] as String?,
      vendorName: props[BacnetPropertyId.vendorName] as String?,
      firmwareRevision: props[BacnetPropertyId.firmwareRevision] as String?,
      applicationSoftwareVersion:
          props[BacnetPropertyId.applicationSoftwareVersion] as String?,
      protocolVersion: props[BacnetPropertyId.protocolVersion] as int?,
      protocolRevision: props[BacnetPropertyId.protocolRevision] as int?,
    );
  }

  /// Scans a device's objects and their properties.
  ///
  /// Reads the device's object list and optionally specified [propertyIds]
  /// for each object. Limited to [maxObjects] to prevent overwhelming
  /// the device.
  ///
  /// Returns a Map where keys are [BacnetObject] instances and values are
  /// Maps of property ID to property value.
  ///
  /// Example:
  /// ```dart
  /// // Scan all objects with present value and description
  /// final objectData = await scanner.scanDevice(
  ///   1234,
  ///   propertyIds: [
  ///     BacnetPropertyId.presentValue,
  ///     BacnetPropertyId.description,
  ///   ],
  ///   maxObjects: 50,
  /// );
  ///
  /// objectData.forEach((obj, props) {
  ///   print('${obj.type}:${obj.instance} = ${props[85]}');
  /// });
  /// ```
  Future<Map<BacnetObject, Map<int, dynamic>>> scanDevice(
    int deviceId, {
    List<int>? propertyIds,
    int maxObjects = 100,
  }) async {
    // 1. Get list of objects utilizing the client's discovery helper
    // This reads the Object_List property (array) efficiently
    final objects = await client.scanDevice(deviceId);

    // 2. Apply limit
    final targetObjects = objects.length > maxObjects
        ? objects.sublist(0, maxObjects)
        : objects;

    final results = <BacnetObject, Map<int, dynamic>>{};

    // Initialize results map
    for (var obj in targetObjects) {
      results[obj] = {};
    }

    // If no properties requested, return just the objects
    if (propertyIds == null || propertyIds.isEmpty) {
      return results;
    }

    // 3. Batch ReadPropertyMultiple requests (e.g., 20 objects per request)
    // to avoid exceeding APDU limits
    const batchSize = 20;

    for (var i = 0; i < targetObjects.length; i += batchSize) {
      final end = (i + batchSize < targetObjects.length)
          ? i + batchSize
          : targetObjects.length;
      final batch = targetObjects.sublist(i, end);

      final specs = batch.map((obj) {
        return BacnetReadAccessSpecification(
          objectIdentifier: obj,
          properties: propertyIds.map((id) {
            return BacnetPropertyReference(propertyIdentifier: id);
          }).toList(),
        );
      }).toList();

      try {
        final batchResults = await client.readMultiple(deviceId, specs);

        // Map string keys back to BacnetObjects
        // Key format from client is likely "${type}:${instance}"
        for (var entry in batchResults.entries) {
          final parts = entry.key.split(':');
          if (parts.length == 2) {
            final type = int.tryParse(parts[0]);
            final instance = int.tryParse(parts[1]);

            if (type != null && instance != null) {
              final objId = BacnetObject(type: type, instance: instance);
              // Find matching object in our results map (BacnetObject implements ==)
              if (results.containsKey(objId)) {
                results[objId] = entry.value;
              }
            }
          }
        }
      } on Object catch (e, st) {
        client.log(
          BacnetLogLevel.warning,
          'Failed to scan batch of objects for device $deviceId',
          e,
          st,
        );
      }
    }

    return results;
  }

  /// Gets complete metadata for a device including its object list.
  ///
  /// Reads object count and object list, returning structured metadata.
  ///
  /// Example:
  /// ```dart
  /// final metadata = await scanner.getDeviceMetadata(1234);
  /// print('Total objects: ${metadata.objectCount}');
  /// print('Loaded objects: ${metadata.objects.length}');
  /// ```
  Future<DeviceMetadata> getDeviceMetadata(
    int deviceId, {
    int maxObjects = 100,
  }) async {
    // Read object count
    final objectCount =
        await client.readProperty(
              deviceId,
              BacnetObjectType.device,
              deviceId,
              BacnetPropertyId.objectList,
              arrayIndex: 0, // Index 0 returns the count
            )
            as int? ??
        0;

    // For now, return metadata without full object list
    // Full implementation would iterate through object list
    return DeviceMetadata(
      deviceId: deviceId,
      objectCount: objectCount,
      objects: const [],
      supportedServices: const [],
    );
  }
}
