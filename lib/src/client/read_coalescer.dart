import 'dart:async';

import '../constants/errors.dart';
import '../constants/object_types.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import '../models/bacnet_value.dart';
import '../models/rpm_models.dart';

/// Sends one ReadProperty request.
typedef ReadPropertyCall =
    Future<BacnetValue> Function(
      int deviceId,
      BacnetObjectType objectType,
      int instance,
      BacnetPropertyId propertyId,
      Duration? timeout, {
      bool background,
    });

/// Sends one ReadPropertyMultiple request (see `BacnetClient.readMultiple`).
typedef ReadMultipleCall =
    Future<Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>>>
    Function(
      int deviceId,
      List<BacnetReadAccessSpecification> specs,
      Duration? timeout, {
      bool background,
    });

/// Merges concurrent ReadProperty calls to one device into
/// ReadPropertyMultiple requests.
///
/// - Reads issued in the same event loop turn (or within [window]) are
///   collected per device, timeout and background flag, up to
///   [maxBatchSize] properties per
///   request; identical reads share one result.
/// - A batch with a single read is sent as ReadProperty.
/// - Property access errors fail only the affected read, with the same
///   [BacnetProtocolException] a ReadProperty would produce.
/// - When the request fails for another reason than the device being
///   unreachable, the reads are retried one by one; devices that reject
///   ReadPropertyMultiple are not batched again.
final class ReadCoalescer {
  /// Creates a coalescer that sends requests with [readProperty] and
  /// [readMultiple].
  ReadCoalescer({
    required ReadPropertyCall readProperty,
    required ReadMultipleCall readMultiple,
    this.maxBatchSize = 24,
    this.window = Duration.zero,
  }) : assert(maxBatchSize > 0),
       _readProperty = readProperty,
       _readMultiple = readMultiple;

  /// Maximum number of properties per ReadPropertyMultiple request.
  final int maxBatchSize;

  /// Time to wait for further reads; zero batches the reads of the current
  /// event loop turn.
  final Duration window;

  final ReadPropertyCall _readProperty;
  final ReadMultipleCall _readMultiple;
  final Map<(int, Duration?, bool), _Batch> _pending = {};
  final Set<int> _withoutMultiple = {};

  /// Devices that do not support ReadPropertyMultiple.
  Iterable<int> get devicesWithoutMultiple => _withoutMultiple;

  /// Reads a property; the request is sent together with other pending
  /// reads of the device.
  Future<BacnetValue> read(
    int deviceId,
    BacnetObjectType objectType,
    int instance,
    BacnetPropertyId propertyId, {
    Duration? timeout,
    bool background = false,
  }) {
    if (_withoutMultiple.contains(deviceId)) {
      return _readProperty(
        deviceId,
        objectType,
        instance,
        propertyId,
        timeout,
        background: background,
      );
    }
    final key = (deviceId, timeout, background);
    var batch = _pending[key];
    if (batch == null) {
      batch = _pending[key] = _Batch(deviceId, timeout, background);
      _schedule(key, batch);
    }
    final read = batch.reads.putIfAbsent((
      objectType,
      instance,
      propertyId,
    ), () => _Read(objectType, instance, propertyId));
    if (batch.reads.length >= maxBatchSize) {
      _pending.remove(key);
      _send(batch);
    }
    return read.completer.future;
  }

  void _schedule((int, Duration?, bool) key, _Batch batch) {
    void flush() {
      // the batch may have been sent already because it was full
      if (identical(_pending[key], batch)) {
        _pending.remove(key);
        _send(batch);
      }
    }

    if (window == Duration.zero) {
      scheduleMicrotask(flush);
    } else {
      Timer(window, flush);
    }
  }

  void _send(_Batch batch) {
    final reads = batch.reads.values.toList(growable: false);
    if (reads.length == 1 || _withoutMultiple.contains(batch.deviceId)) {
      reads.forEach(batch.readSingle(_readProperty));
    } else {
      unawaited(_sendMultiple(batch, reads));
    }
  }

  Future<void> _sendMultiple(_Batch batch, List<_Read> reads) async {
    final Map<BacnetObject, Map<BacnetPropertyId, BacnetPropertyResult>> result;
    try {
      result = await _readMultiple(
        batch.deviceId,
        _specs(reads),
        batch.timeout,
        background: batch.background,
      );
    } on BacnetException catch (error, stack) {
      if (_unreachable(error)) {
        for (final read in reads) {
          read.completer.completeError(error, stack);
        }
        return;
      }
      if (_unsupported(error)) _withoutMultiple.add(batch.deviceId);
      reads.forEach(batch.readSingle(_readProperty));
      return;
    }
    for (final read in reads) {
      final object = BacnetObject(
        type: read.objectType,
        instance: read.instance,
      );
      switch (result[object]?[read.propertyId]) {
        case final BacnetValue value:
          read.completer.complete(value);
        case BacnetError(:final errorClass, :final errorCode):
          read.completer.completeError(
            BacnetProtocolException(
              'device ${batch.deviceId} returned an error',
              errorClass: errorClass,
              errorCode: errorCode,
            ),
          );
        case null:
          // the device left the property out: ask for it alone
          batch.readSingle(_readProperty)(read);
      }
    }
  }

  static List<BacnetReadAccessSpecification> _specs(List<_Read> reads) {
    final byObject = <(BacnetObjectType, int), List<BacnetPropertyReference>>{};
    for (final read in reads) {
      (byObject[(read.objectType, read.instance)] ??= []).add(
        BacnetPropertyReference(propertyIdentifier: read.propertyId),
      );
    }
    return [
      for (final MapEntry(key: (type, instance), value: properties)
          in byObject.entries)
        BacnetReadAccessSpecification(
          objectIdentifier: BacnetObject(type: type, instance: instance),
          properties: properties,
        ),
    ];
  }

  /// Failures that a retry with single reads would only repeat.
  static bool _unreachable(BacnetException error) =>
      error is BacnetTimeoutException ||
      error is BacnetDeviceNotFoundException ||
      error is BacnetQueueFullException ||
      error is BacnetNotInitializedException;

  /// Answers of devices that do not implement ReadPropertyMultiple.
  static bool _unsupported(BacnetException error) =>
      error is BacnetRejectException ||
      (error is BacnetProtocolException &&
          error.errorClass == BacnetErrorClass.services);
}

final class _Batch {
  _Batch(this.deviceId, this.timeout, this.background);

  final int deviceId;
  final Duration? timeout;
  final bool background;
  final Map<(BacnetObjectType, int, BacnetPropertyId), _Read> reads = {};

  void Function(_Read) readSingle(ReadPropertyCall readProperty) =>
      (read) => read.completer.complete(
        readProperty(
          deviceId,
          read.objectType,
          read.instance,
          read.propertyId,
          timeout,
          background: background,
        ),
      );
}

final class _Read {
  _Read(this.objectType, this.instance, this.propertyId);

  final BacnetObjectType objectType;
  final int instance;
  final BacnetPropertyId propertyId;
  final Completer<BacnetValue> completer = Completer<BacnetValue>();
}
