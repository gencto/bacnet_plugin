import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../codec/writer.dart';
import '../codec/value_encoding.dart';
import '../constants/property_ids.dart';
import '../core/bacnet_config.dart';
import '../core/exceptions.dart';
import '../core/logger.dart';
import '../models/events.dart';
import '../native/bacnet_system.dart';
import '../native/protocol.dart';

/// One present value update for [BacnetServer.updatePresentValues].
@immutable
class BacnetPresentValueUpdate {
  /// Creates an update. [value] is a number, a bool (binary objects) or
  /// `null` to relinquish [priority] of commandable objects.
  const BacnetPresentValueUpdate({
    required this.objectType,
    required this.instance,
    required this.value,
    this.priority = 16,
  });

  /// Object type.
  final int objectType;

  /// Object instance.
  final int instance;

  /// New present value.
  final Object? value;

  /// Priority for commandable objects (1..16).
  final int priority;
}

/// BACnet server hosting objects and answering client requests.
///
/// Read/write/COV requests from the network are answered entirely by the
/// native stack in the worker isolate (no Dart code runs per request), so a
/// server keeps up with many clients. Values are pushed from Dart with
/// [setPresentValue] or, for many points at once, [updatePresentValues].
///
/// ```dart
/// final server = BacnetServer(config: const BacnetConfig(interface: 'eth0'));
/// await server.start();
/// await server.init(4194300, 'Flutter BACnet Server');
/// await server.addObject(BacnetObjectType.analogInput, 1,
///     name: 'Supply Air Temp',
///     units: BacnetEngineeringUnits.degreesCelsius, covIncrement: 0.1);
/// await server.setPresentValue(BacnetObjectType.analogInput, 1, 21.5);
///
/// server.writeEvents.listen((event) {
///   print('${event.objectType}:${event.instance} <- ${event.value}');
/// });
/// ```
class BacnetServer {
  /// Creates a BACnet server.
  ///
  /// [logger] overrides [BacnetConfig.logger].
  BacnetServer({BacnetLogger? logger, BacnetConfig? config})
    : _config = config ?? const BacnetConfig() {
    if (logger != null) {
      _system.setLogger(logger);
    }
  }

  final BacnetConfig _config;
  final BacnetSystem _system = BacnetSystem.instance;
  bool _started = false;

  /// Configuration of this server.
  BacnetConfig get config => _config;

  /// Writes performed by remote clients on objects of this server.
  Stream<PropertyWriteEvent> get writeEvents => _system.events
      .where((e) => e is PropertyWriteEvent)
      .cast<PropertyWriteEvent>();

  /// Starts the BACnet stack (shared with [BacnetClient] instances).
  Future<void> start({String? interface, int? port}) async {
    if (_started) return;
    await _system.start(_config.copyWith(interface: interface, port: port));
    _started = true;
  }

  /// Initializes the local Device object and starts answering requests
  /// (Who-Is, Read/WriteProperty(Multiple), SubscribeCOV(Property),
  /// ReadRange, DeviceCommunicationControl, ReinitializeDevice and time
  /// synchronization). Sends an I-Am.
  ///
  /// ```dart
  /// await server.init(4194300, 'Building Controller', vendorName: 'ACME');
  /// ```
  Future<void> init(
    int deviceId,
    String deviceName, {
    int? vendorId,
    String? vendorName,
    String? modelName,
    String? description,
    String? location,
    String? firmwareRevision,
    String? applicationSoftwareVersion,
  }) {
    return _system.call<void>(
      (id) => ServerEnableCommand(
        id,
        deviceId: deviceId,
        deviceName: deviceName,
        vendorId: vendorId,
        strings: {
          BacnetPropertyId.vendorName: ?vendorName,
          BacnetPropertyId.modelName: ?modelName,
          BacnetPropertyId.description: ?description,
          BacnetPropertyId.location: ?location,
          BacnetPropertyId.firmwareRevision: ?firmwareRevision,
          BacnetPropertyId.applicationSoftwareVersion:
              ?applicationSoftwareVersion,
        },
      ),
    );
  }

  /// Adds an object to the server and returns its instance.
  ///
  /// Supported types: Analog/Binary/Multi-state Input/Output/Value, Integer
  /// Value, Positive Integer Value, CharacterString Value and every other
  /// object type of bacnet-stack that supports CreateObject.
  /// [stateTexts] defines the states of multi-state objects.
  Future<int> addObject(
    int objectType,
    int instance, {
    String? name,
    String? description,
    int? units,
    double? covIncrement,
    bool? outOfService,
    List<String>? stateTexts,
    Object? presentValue,
  }) async {
    final result = await _system.call<Object?>(
      (id) => CreateObjectCommand(
        id,
        objectType: objectType,
        instance: instance,
        name: name,
        description: description,
        stateTexts: stateTexts,
        numbers: {
          if (units != null) BacnetPropertyId.units: units.toDouble(),
          BacnetPropertyId.covIncrement: ?covIncrement,
          if (outOfService != null)
            BacnetPropertyId.outOfService: outOfService ? 1 : 0,
        },
        presentValue: presentValue is String ? null : _number(presentValue),
        presentValueString: presentValue is String ? presentValue : null,
      ),
    );
    return result is int ? result : instance;
  }

  /// Removes an object from the server.
  Future<void> removeObject(int objectType, int instance) =>
      _system.call<void>((id) => DeleteObjectCommand(id, objectType, instance));

  /// Sets the present value of an object (local update, triggers COV
  /// notifications to subscribers).
  ///
  /// [value] is a number, a bool (binary objects), a String (CharacterString
  /// Value) or `null` to relinquish [priority] of commandable objects.
  Future<void> setPresentValue(
    int objectType,
    int instance,
    Object? value, {
    int priority = 16,
  }) {
    if (value is String) {
      return _system.call<void>(
        (id) => SetTextCommand(
          id,
          objectType: objectType,
          instance: instance,
          propertyId: BacnetPropertyId.presentValue,
          value: value,
        ),
      );
    }
    return _system.call<void>(
      (id) => SetNumberCommand(
        id,
        objectType: objectType,
        instance: instance,
        propertyId: BacnetPropertyId.presentValue,
        value: _number(value) ?? double.nan,
        priority: priority,
      ),
    );
  }

  /// Applies many present value updates in one native call and returns the
  /// number of applied updates. Use it to feed thousands of points per
  /// second from a data source.
  Future<int> updatePresentValues(Iterable<BacnetPresentValueUpdate> updates) {
    final list = updates.toList(growable: false);
    if (list.isEmpty) return Future.value(0);
    final packed = ByteData(list.length * 16);
    for (var i = 0; i < list.length; i++) {
      final update = list[i];
      final at = i * 16;
      packed
        ..setUint32(at, update.instance, Endian.host)
        ..setUint16(at + 4, update.objectType, Endian.host)
        ..setUint8(at + 6, update.priority)
        ..setFloat64(at + 8, _number(update.value) ?? double.nan, Endian.host);
    }
    final transferable = TransferableTypedData.fromList([
      packed.buffer.asUint8List(),
    ]);
    return _system.call<int>(
      (id) => SetPresentValuesCommand(id, transferable, list.length),
    );
  }

  /// Sets out-of-service of an object.
  Future<void> setOutOfService(int objectType, int instance, bool value) =>
      _system.call<void>(
        (id) => SetNumberCommand(
          id,
          objectType: objectType,
          instance: instance,
          propertyId: BacnetPropertyId.outOfService,
          value: value ? 1 : 0,
        ),
      );

  /// Sets the object name.
  Future<void> setObjectName(int objectType, int instance, String name) =>
      _system.call<void>(
        (id) => SetTextCommand(
          id,
          objectType: objectType,
          instance: instance,
          propertyId: BacnetPropertyId.objectName,
          value: name,
        ),
      );

  /// Writes any property of a local object with WriteProperty semantics
  /// (the same checks as a remote write, no write notification).
  Future<void> setProperty(
    int objectType,
    int instance,
    int propertyId,
    Object? value, {
    int priority = 16,
    int? tag,
    int arrayIndex = -1,
  }) {
    final writer = BacnetWriter();
    encodeApplicationValue(
      writer,
      value,
      tag: tag ?? inferApplicationTag(objectType, propertyId, value),
    );
    final payload = writer.toBytes();
    return _system.call<void>(
      (id) => LocalWriteCommand(
        id,
        objectType: objectType,
        instance: instance,
        propertyId: propertyId,
        payload: payload,
        arrayIndex: arrayIndex,
        priority: priority,
      ),
    );
  }

  /// Reads a property of a local object.
  Future<dynamic> readProperty(
    int objectType,
    int instance,
    int propertyId, {
    int arrayIndex = -1,
  }) {
    return _system.call<Object?>(
      (id) => LocalReadCommand(
        id,
        objectType: objectType,
        instance: instance,
        propertyId: propertyId,
        arrayIndex: arrayIndex,
      ),
    );
  }

  /// Broadcasts an I-Am for the local device.
  Future<void> sendIAm() => _system.call<void>(SendIAmCommand.new);

  static double? _number(Object? value) => switch (value) {
    null => null,
    bool v => v ? 1 : 0,
    num v => v.toDouble(),
    _ => throw BacnetEncodeException(
      'unsupported present value type ${value.runtimeType}',
    ),
  };

  /// Releases the stack (stopped when no client or server uses it).
  Future<void> close() async {
    if (!_started) return;
    _started = false;
    await _system.release();
  }

  /// Disposes of the server and releases resources.
  ///
  /// Prefer [close] to await the shutdown.
  void dispose() {
    unawaited(close());
  }
}
