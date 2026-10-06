import 'dart:async';

import '../client/bacnet_client.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import '../core/types.dart';
import '../models/bacnet_value.dart';
import '../models/device_description.dart';
import '../models/rpm_models.dart';
import 'device_scanner.dart' show mapConcurrent;

/// Properties read from devices without ReadPropertyMultiple or
/// Property_List (before protocol revision 14).
const _basicProperties = [
  BacnetPropertyId.objectIdentifier,
  BacnetPropertyId.objectName,
  BacnetPropertyId.objectType,
  BacnetPropertyId.presentValue,
  BacnetPropertyId.description,
  BacnetPropertyId.statusFlags,
  BacnetPropertyId.eventState,
  BacnetPropertyId.reliability,
  BacnetPropertyId.outOfService,
  BacnetPropertyId.units,
  BacnetPropertyId.priorityArray,
  BacnetPropertyId.relinquishDefault,
  BacnetPropertyId.covIncrement,
  BacnetPropertyId.stateText,
  BacnetPropertyId.numberOfStates,
  BacnetPropertyId.activeText,
  BacnetPropertyId.inactiveText,
  BacnetPropertyId.polarity,
];

/// Reads everything a device tells about itself into a
/// [BacnetDeviceDescription] (inventories, commissioning reports, comparing
/// a device with an earlier state).
///
/// ```dart
/// final description = await client.describeDevice(
///   1234,
///   onProgress: (done, total) => print('$done / $total objects'),
/// );
/// print(description.toEpics());
/// ```
extension BacnetDeviceDescriptions on BacnetClient {
  /// Reads all properties of all objects of [deviceId]: ReadPropertyMultiple
  /// with ALL for [batchSize] objects at a time, [concurrency] batches in
  /// parallel; objects the device cannot describe that way (no
  /// ReadPropertyMultiple, answers too large) are read property by property
  /// from their Property_List. [onProgress] reports the objects read.
  ///
  /// The requests run in the background ([BacnetClient.readMultiple]), so
  /// that the application's own requests overtake them.
  Future<BacnetDeviceDescription> describeDevice(
    int deviceId, {
    int batchSize = 8,
    int concurrency = 2,
    void Function(int done, int total)? onProgress,
  }) async {
    final time = DateTime.now();
    final objects = await scanDevice(deviceId, background: true);
    final properties = <BacnetObject, Map<BacnetPropertyId, BacnetValue>>{
      for (final object in objects) object: const {},
    };
    final batches = [
      for (var i = 0; i < objects.length; i += batchSize)
        objects.sublist(
          i,
          i + batchSize < objects.length ? i + batchSize : objects.length,
        ),
    ];
    var done = 0;
    var readMultipleWorks = true;
    onProgress?.call(0, objects.length);
    await mapConcurrent(batches, concurrency, (batch) async {
      Map<BacnetObject, Map<BacnetPropertyId, BacnetValue>>? read;
      if (readMultipleWorks) {
        try {
          read = await _readAll(deviceId, batch);
        } on BacnetRejectException {
          readMultipleWorks = false; // no ReadPropertyMultiple
        } on BacnetException catch (e) {
          log(
            BacnetLogLevel.debug,
            'ReadPropertyMultiple ALL of $deviceId failed, '
            'reading the objects one by one',
            e,
          );
        }
      }
      for (final object in batch) {
        properties[object] =
            read?[object] ?? await _readOneByOne(deviceId, object);
        onProgress?.call(++done, objects.length);
      }
    });
    return BacnetDeviceDescription(
      deviceId: deviceId,
      time: time,
      objects: properties,
    );
  }

  Future<Map<BacnetObject, Map<BacnetPropertyId, BacnetValue>>> _readAll(
    int deviceId,
    List<BacnetObject> objects,
  ) async {
    final results = await readMultiple(deviceId, [
      for (final object in objects)
        BacnetReadAccessSpecification(
          objectIdentifier: object,
          properties: const [
            BacnetPropertyReference(propertyIdentifier: BacnetPropertyId.all),
          ],
        ),
    ], background: true);
    return {
      for (final MapEntry(key: object, value: properties) in results.entries)
        if (properties.values.any((result) => result is BacnetValue))
          object: {
            for (final MapEntry(key: id, value: result) in properties.entries)
              if (result case final BacnetValue value) id: value,
          },
    };
  }

  /// Reads the properties of [object] one at a time.
  Future<Map<BacnetPropertyId, BacnetValue>> _readOneByOne(
    int deviceId,
    BacnetObject object,
  ) async {
    Future<BacnetValue?> property(BacnetPropertyId id) =>
        readProperty(
              deviceId,
              object.type,
              object.instance,
              id,
              background: true,
            )
            .then<BacnetValue?>((value) => value)
            .catchError((Object _) => null, test: (e) => e is BacnetException);

    final list = await property(BacnetPropertyId.propertyList);
    final ids = list is BacnetList
        ? [
            BacnetPropertyId.objectIdentifier,
            BacnetPropertyId.objectName,
            BacnetPropertyId.objectType,
            for (final item in list.items)
              if (item case BacnetEnumerated(:final value))
                BacnetPropertyId(value),
          ]
        : [
            ..._basicProperties,
            if (object.type == BacnetObjectType.device) ...[
              BacnetPropertyId.vendorName,
              BacnetPropertyId.vendorIdentifier,
              BacnetPropertyId.modelName,
              BacnetPropertyId.firmwareRevision,
              BacnetPropertyId.applicationSoftwareVersion,
              BacnetPropertyId.protocolVersion,
              BacnetPropertyId.protocolRevision,
              BacnetPropertyId.protocolServicesSupported,
              BacnetPropertyId.protocolObjectTypesSupported,
              BacnetPropertyId.maxApduLengthAccepted,
              BacnetPropertyId.segmentationSupported,
              BacnetPropertyId.systemStatus,
            ],
          ];
    final values = <BacnetPropertyId, BacnetValue>{};
    for (final id in ids) {
      if (values.containsKey(id)) continue;
      // the object list was read already, maybe segmented
      if (id == BacnetPropertyId.objectList) continue;
      if (await property(id) case final value?) values[id] = value;
    }
    return values;
  }
}
