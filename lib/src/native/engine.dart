import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../constants/errors.dart';
import '../constants/property_ids.dart';
import '../core/exceptions.dart';
import 'bindings.g.dart';
import 'native_errors.dart';

/// Address binding of a device as stored by the native engine.
typedef NativeDeviceBinding = ({List<int> mac, int network, int maxApdu});

/// Counters of the native engine.
typedef NativeStats = ({
  int packetsReceived,
  int requestsSent,
  int repliesDropped,
  int eventsDropped,
  int boundDevices,
  int freeTransactions,
  int pollCalls,
  int segmentedReplies,
});

/// Typed facade over the native engine (`native/src/bacnet_plugin.h`).
///
/// Owns all native memory handling and turns result codes into exceptions.
/// The engine is process global and not thread safe: use one instance from
/// one isolate (the worker) only. Only `bacnet_plugin_wakeup` may be called
/// from other isolates.
class NativeEngine {
  /// Creates the facade; call [init] before anything else.
  NativeEngine();

  static const int _scratchSize = 2048;
  final ffi.Pointer<ffi.Uint8> _scratch = calloc<ffi.Uint8>(_scratchSize);

  /// Version of the engine and of bacnet-stack.
  String get version => bacnet_plugin_version().cast<Utf8>().toDartString();

  /// Initializes the datalink and the stack.
  void init({
    required String? interface,
    required int port,
    required int deviceInstance,
    required int socketBufferSize,
  }) {
    final rc = _withOptionalString(
      interface,
      (iface) =>
          bacnet_plugin_init(iface, port, deviceInstance, socketBufferSize),
    );
    if (rc != BP_OK) {
      throw BacnetException(
        'Failed to initialize BACnet/IP on '
        '${interface ?? 'default interface'}:$port: ${nativeErrorMessage(rc)}',
      );
    }
  }

  /// Applies runtime options.
  void configure({
    required int apduTimeoutMs,
    required int apduRetries,
    required bool strictSourceCheck,
    required int covScanIntervalMs,
    required int maxSegments,
  }) {
    checkNative(
      bacnet_plugin_set_option(BP_OPTION_APDU_TIMEOUT_MS, apduTimeoutMs),
    );
    checkNative(bacnet_plugin_set_option(BP_OPTION_APDU_RETRIES, apduRetries));
    checkNative(
      bacnet_plugin_set_option(
        BP_OPTION_STRICT_SOURCE,
        strictSourceCheck ? 1 : 0,
      ),
    );
    checkNative(
      bacnet_plugin_set_option(
        BP_OPTION_COV_SCAN_INTERVAL_MS,
        covScanIntervalMs,
      ),
    );
    checkNative(bacnet_plugin_set_option(BP_OPTION_MAX_SEGMENTS, maxSegments));
  }

  /// Waits up to [timeoutMs] for traffic and processes up to [maxPackets].
  int poll(int timeoutMs, int maxPackets) =>
      bacnet_plugin_poll(timeoutMs, maxPackets);

  /// View of the pending native events, valid until [clearEvents] or the
  /// next engine call. Empty when there are no events.
  Uint8List eventsView() {
    final length = bacnet_plugin_events_length();
    if (length == 0) return Uint8List(0);
    return bacnet_plugin_events_data().asTypedList(length);
  }

  /// Discards the pending events.
  void clearEvents() => bacnet_plugin_events_clear();

  /// Sends a confirmed request; returns the invoke id or a negative
  /// `BP_ERR_*` code.
  int sendConfirmed(
    int deviceId,
    int service,
    Uint8List payload, [
    int priority = 0,
  ]) => _withBytes(
    payload,
    (data, length) =>
        bacnet_plugin_send_confirmed(deviceId, service, data, length, priority),
  );

  /// Sends an unconfirmed request to [deviceId] or as broadcast on
  /// [network] (0xFFFF global, 0 local).
  void sendUnconfirmed(
    int service,
    Uint8List payload, {
    int? deviceId,
    int network = 0xFFFF,
  }) {
    checkNative(
      _withBytes(
        payload,
        (data, length) => bacnet_plugin_send_unconfirmed(
          deviceId ?? BP_DEVICE_UNKNOWN,
          network,
          service,
          data,
          length,
        ),
      ),
    );
  }

  /// Adds or replaces a static address binding.
  void bindDevice({
    required int deviceId,
    required String host,
    required int port,
    int network = 0,
    List<int> adr = const [],
    int maxApdu = 1476,
  }) {
    checkNative(
      _withString(
        host,
        (hostPtr) => _withBytes(
          adr,
          (adrPtr, adrLength) => bacnet_plugin_bind_device(
            deviceId,
            hostPtr,
            port,
            network,
            adrPtr,
            adrLength,
            maxApdu,
          ),
        ),
      ),
    );
  }

  /// Removes the address binding of a device.
  void unbindDevice(int deviceId) => bacnet_plugin_unbind_device(deviceId);

  /// The own BACnet/IP address (IPv4 address and port).
  List<int> localAddress() {
    final mac = calloc<ffi.Uint8>(8);
    try {
      final length = checkNative(bacnet_plugin_local_address(mac));
      return List<int>.of(mac.asTypedList(length));
    } finally {
      calloc.free(mac);
    }
  }

  /// Returns the address binding of a device, or null when unknown.
  NativeDeviceBinding? deviceBinding(int deviceId) {
    final mac = calloc<ffi.Uint8>(8);
    final macLength = calloc<ffi.Uint8>();
    final network = calloc<ffi.Uint16>();
    final maxApdu = calloc<ffi.Uint16>();
    try {
      final bound = bacnet_plugin_device_binding(
        deviceId,
        mac,
        macLength,
        network,
        maxApdu,
      );
      if (bound != 1) return null;
      return (
        mac: List<int>.of(mac.asTypedList(macLength.value)),
        network: network.value,
        maxApdu: maxApdu.value,
      );
    } finally {
      calloc
        ..free(mac)
        ..free(macLength)
        ..free(network)
        ..free(maxApdu);
    }
  }

  /// Registers as foreign device with a BBMD (renewed automatically).
  void registerForeignDevice(String host, int port, int ttl) {
    checkNative(
      _withString(
        host,
        (hostPtr) => bacnet_plugin_register_foreign_device(hostPtr, port, ttl),
      ),
    );
  }

  /// Enables the server role of the local device.
  void enableServer(int deviceId, String deviceName) {
    checkNative(
      _withString(
        deviceName,
        (name) => bacnet_plugin_server_enable(deviceId, name),
      ),
    );
  }

  /// Sets a string property of the local Device object.
  void setDeviceString(int propertyId, String value) {
    checkNative(
      _withString(
        value,
        (text) => bacnet_plugin_device_set_string(propertyId, text),
      ),
    );
  }

  /// Sets the vendor identifier of the local Device object.
  void setVendorId(int vendorId) =>
      checkNative(bacnet_plugin_device_set_vendor_id(vendorId));

  /// Broadcasts an I-Am of the local device.
  void sendIAm() => checkNative(bacnet_plugin_send_i_am());

  /// Creates a server object and returns its instance.
  int createObject(int objectType, int instance) {
    final errorClass = calloc<ffi.Uint32>();
    final errorCode = calloc<ffi.Uint32>();
    try {
      final created = bacnet_plugin_object_create(
        objectType,
        instance,
        errorClass,
        errorCode,
      );
      if (created == BP_ERR_OBJECT) {
        throw BacnetProtocolException(
          'CreateObject $objectType:$instance failed',
          errorClass: BacnetErrorClass(errorClass.value),
          errorCode: BacnetErrorCode(errorCode.value),
        );
      }
      return checkNative(created);
    } finally {
      calloc
        ..free(errorClass)
        ..free(errorCode);
    }
  }

  /// Deletes a server object.
  void deleteObject(int objectType, int instance) =>
      checkNative(bacnet_plugin_object_delete(objectType, instance));

  /// Sets the name ([BacnetPropertyId.objectName]), the description
  /// ([BacnetPropertyId.description]) or the present value of a
  /// CharacterString Value object.
  void setObjectText(
    int objectType,
    int instance,
    int propertyId,
    String value,
  ) {
    checkNative(
      _withString(
        value,
        (text) => switch (propertyId) {
          BacnetPropertyId.objectName => bacnet_plugin_object_set_name(
            objectType,
            instance,
            text,
          ),
          BacnetPropertyId.description => bacnet_plugin_object_set_description(
            objectType,
            instance,
            text,
          ),
          _ => bacnet_plugin_object_set_string(objectType, instance, text),
        },
      ),
    );
  }

  /// Sets the state texts of a multi-state object.
  void setStateTexts(int objectType, int instance, List<String> states) {
    // NUL separated list terminated by an empty string
    final bytes = [...utf8.encode('${states.join('\u0000')}\u0000'), 0];
    checkNative(
      _withBytes(
        bytes,
        (data, length) => bacnet_plugin_object_set_state_texts(
          objectType,
          instance,
          data.cast(),
          length,
        ),
      ),
    );
  }

  /// Sets a numeric property locally (present value, out of service,
  /// units, COV increment).
  void setNumber(
    int objectType,
    int instance,
    int propertyId,
    double value, [
    int priority = 16,
  ]) {
    checkNative(
      bacnet_plugin_object_set_number(
        objectType,
        instance,
        propertyId,
        value,
        priority,
      ),
    );
  }

  /// Applies packed `bp_present_value_update_t` records; returns the
  /// number of applied updates.
  int setPresentValues(Uint8List packed, int count) {
    final ptr = calloc<ffi.Uint8>(packed.length);
    try {
      ptr.asTypedList(packed.length).setAll(0, packed);
      return checkNative(
        bacnet_plugin_object_set_present_values(ptr.cast(), count),
      );
    } finally {
      calloc.free(ptr);
    }
  }

  /// Writes an application encoded value with WriteProperty semantics.
  void writeProperty({
    required int objectType,
    required int instance,
    required int propertyId,
    required Uint8List payload,
    int arrayIndex = -1,
    int priority = 16,
  }) {
    final errorClass = calloc<ffi.Uint32>();
    final errorCode = calloc<ffi.Uint32>();
    try {
      final rc = _withBytes(
        payload,
        (data, length) => bacnet_plugin_object_write(
          objectType,
          instance,
          propertyId,
          arrayIndex,
          priority,
          data,
          length,
          errorClass,
          errorCode,
        ),
      );
      if (rc == BP_ERR_OBJECT) {
        throw BacnetProtocolException(
          'write $objectType:$instance property $propertyId failed',
          errorClass: BacnetErrorClass(errorClass.value),
          errorCode: BacnetErrorCode(errorCode.value),
        );
      }
      checkNative(rc);
    } finally {
      calloc
        ..free(errorClass)
        ..free(errorCode);
    }
  }

  /// Reads a property of a local object as application encoded data.
  Uint8List readProperty({
    required int objectType,
    required int instance,
    required int propertyId,
    int arrayIndex = -1,
  }) {
    const capacity = 1476;
    final buffer = calloc<ffi.Uint8>(capacity);
    final errorClass = calloc<ffi.Uint32>();
    final errorCode = calloc<ffi.Uint32>();
    try {
      final length = bacnet_plugin_object_read(
        objectType,
        instance,
        propertyId,
        arrayIndex,
        buffer,
        capacity,
        errorClass,
        errorCode,
      );
      if (length == BP_ERR_OBJECT) {
        throw BacnetProtocolException(
          'read $objectType:$instance property $propertyId failed',
          errorClass: BacnetErrorClass(errorClass.value),
          errorCode: BacnetErrorCode(errorCode.value),
        );
      }
      return Uint8List.fromList(buffer.asTypedList(checkNative(length)));
    } finally {
      calloc
        ..free(buffer)
        ..free(errorClass)
        ..free(errorCode);
    }
  }

  /// Returns the engine counters.
  NativeStats stats() {
    final stats = calloc<bp_stats_t>();
    try {
      bacnet_plugin_stats(stats);
      final s = stats.ref;
      return (
        packetsReceived: s.packets_received,
        requestsSent: s.requests_sent,
        repliesDropped: s.replies_dropped,
        eventsDropped: s.events_dropped,
        boundDevices: s.bound_devices,
        freeTransactions: s.tsm_idle,
        pollCalls: s.poll_calls,
        segmentedReplies: s.segmented_replies,
      );
    } finally {
      calloc.free(stats);
    }
  }

  /// Closes the sockets and releases the native resources of the stack.
  void shutdown() {
    bacnet_plugin_shutdown();
    calloc.free(_scratch);
  }

  T _withString<T>(String value, T Function(ffi.Pointer<ffi.Char>) body) {
    final ptr = value.toNativeUtf8();
    try {
      return body(ptr.cast());
    } finally {
      calloc.free(ptr);
    }
  }

  T _withOptionalString<T>(
    String? value,
    T Function(ffi.Pointer<ffi.Char>) body,
  ) => value == null ? body(ffi.nullptr) : _withString(value, body);

  /// Copies [bytes] to native memory for the duration of [body]; payloads
  /// up to 2 KiB reuse one buffer (the hot path of every request).
  T _withBytes<T>(
    List<int> bytes,
    T Function(ffi.Pointer<ffi.Uint8> data, int length) body,
  ) {
    if (bytes.isEmpty) return body(ffi.nullptr, 0);
    if (bytes.length <= _scratchSize) {
      _scratch.asTypedList(bytes.length).setAll(0, bytes);
      return body(_scratch, bytes.length);
    }
    final ptr = calloc<ffi.Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return body(ptr, bytes.length);
    } finally {
      calloc.free(ptr);
    }
  }
}
