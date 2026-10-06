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

  /// Sends an unconfirmed request to [deviceId], to [mac] (and [adr] on
  /// [network] behind a router) or as broadcast on [network] (0xFFFF
  /// global, 0 local).
  void sendUnconfirmed(
    int service,
    Uint8List payload, {
    int? deviceId,
    int network = 0xFFFF,
    List<int>? mac,
    List<int> adr = const [],
  }) {
    if (mac != null) {
      // one buffer: _withBytes reuses the same scratch memory
      final bytes = Uint8List(mac.length + adr.length + payload.length)
        ..setAll(0, mac)
        ..setAll(mac.length, adr)
        ..setAll(mac.length + adr.length, payload);
      checkNative(
        _withBytes(
          bytes,
          (data, _) => bacnet_plugin_send_unconfirmed_to(
            mac.isEmpty ? ffi.nullptr : data,
            mac.length,
            network,
            adr.isEmpty ? ffi.nullptr : data + mac.length,
            adr.length,
            service,
            payload.isEmpty ? ffi.nullptr : data + mac.length + adr.length,
            payload.length,
          ),
        ),
      );
      return;
    }
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

  /// Sends a network layer message to [mac] (a local broadcast when
  /// empty), on [network] to [adr] behind a router.
  void sendNetworkMessage({
    required int messageType,
    required Uint8List payload,
    List<int> mac = const [],
    int network = 0,
    List<int> adr = const [],
    int vendorId = 0,
  }) {
    // one buffer: _withBytes reuses the same scratch memory
    final bytes = Uint8List(mac.length + adr.length + payload.length)
      ..setAll(0, mac)
      ..setAll(mac.length, adr)
      ..setAll(mac.length + adr.length, payload);
    checkNative(
      _withBytes(
        bytes,
        (data, _) => bacnet_plugin_send_network(
          mac.isEmpty ? ffi.nullptr : data,
          mac.length,
          network,
          adr.isEmpty ? ffi.nullptr : data + mac.length,
          adr.length,
          messageType,
          vendorId,
          payload.isEmpty ? ffi.nullptr : data + mac.length + adr.length,
          payload.length,
        ),
      ),
    );
  }

  /// Appends a record with the application encoded [payload] to Trend Log
  /// [instance] of the server; false while the log is disabled.
  bool appendTrendLog(int instance, Uint8List payload, int statusFlags) =>
      checkNative(
        _withBytes(
          payload,
          (data, length) => bacnet_plugin_trend_log_append(
            instance,
            data,
            length,
            statusFlags,
          ),
        ),
      ) ==
      1;

  /// Lets clients back up and restore the server.
  void configureBackup(
    List<int> files, {
    required bool prepare,
    required bool apply,
    required int failureTimeoutSeconds,
  }) {
    final array = calloc<ffi.Uint32>(files.isEmpty ? 1 : files.length);
    try {
      array.asTypedList(files.length).setAll(0, files);
      checkNative(
        bacnet_plugin_backup_configure(
          array,
          files.length,
          (prepare ? BP_BACKUP_PREPARE : 0) | (apply ? BP_BACKUP_APPLY : 0),
          failureTimeoutSeconds,
        ),
      );
    } finally {
      calloc.free(array);
    }
  }

  /// Sets Backup_And_Restore_State of the server.
  void setBackupState(int state) =>
      checkNative(bacnet_plugin_backup_set_state(state));

  /// Changes the instance of the local Device object and sends an I-Am.
  void setDeviceInstance(int deviceId) =>
      checkNative(bacnet_plugin_device_set_instance(deviceId));

  /// Replaces the content of File object [instance] of the server.
  void setFileContent(int instance, Uint8List content) {
    checkNative(
      _withBytes(
        content,
        (data, length) =>
            bacnet_plugin_file_set_content(instance, data, length),
      ),
    );
  }

  /// The content of File object [instance] of the server.
  Uint8List fileContent(int instance) {
    final size = checkNative(
      bacnet_plugin_file_get_content(instance, 0, ffi.nullptr, 0),
    );
    if (size == 0) return Uint8List(0);
    final buffer = calloc<ffi.Uint8>(size);
    try {
      final now = checkNative(
        bacnet_plugin_file_get_content(instance, 0, buffer, size),
      );
      return Uint8List.fromList(buffer.asTypedList(now < size ? now : size));
    } finally {
      calloc.free(buffer);
    }
  }

  /// Sets File_Type, Read_Only and the size limit of remote writes of
  /// File object [instance] (null keeps them).
  void configureFile(
    int instance, {
    String? fileType,
    bool? readOnly,
    int? maxSize,
  }) {
    checkNative(
      _withOptionalString(
        fileType,
        (type) => bacnet_plugin_file_configure(
          instance,
          type,
          readOnly == null ? -1 : (readOnly ? 1 : 0),
          maxSize ?? -1,
        ),
      ),
    );
  }

  /// Configures the Time Master and replaces its recipients. When [enabled]
  /// the server sends a (UTC)TimeSynchronization every [intervalSeconds] to
  /// [recipients] (a device, an address, or a broadcast when the mac is
  /// empty), optionally aligned to the wall clock [offsetSeconds] past each
  /// interval.
  void configureTimeMaster({
    required bool enabled,
    required int intervalSeconds,
    required bool utc,
    required bool align,
    required int offsetSeconds,
    required List<({int deviceId, List<int> mac, int network, List<int> adr})>
    recipients,
  }) {
    checkNative(bacnet_plugin_time_master_clear_recipients());
    for (final recipient in recipients) {
      final mac = recipient.mac;
      final adr = recipient.adr;
      final bytes = Uint8List(mac.length + adr.length)
        ..setAll(0, mac)
        ..setAll(mac.length, adr);
      checkNative(
        _withBytes(
          bytes,
          (data, _) => bacnet_plugin_time_master_add_recipient(
            recipient.deviceId,
            mac.isEmpty ? ffi.nullptr : data,
            mac.length,
            recipient.network,
            adr.isEmpty ? ffi.nullptr : data + mac.length,
            adr.length,
          ),
        ),
      );
    }
    checkNative(
      bacnet_plugin_time_master_configure(
        enabled ? 1 : 0,
        intervalSeconds,
        utc ? 1 : 0,
        align ? 1 : 0,
        offsetSeconds,
      ),
    );
  }

  /// Configures Event Enrollment object [instance] (created first with an
  /// object create) with the OUT_OF_RANGE event algorithm on the monitored
  /// property.
  void configureEventEnrollment(
    int instance, {
    required int monitoredType,
    required int monitoredInstance,
    required int monitoredProperty,
    required int monitoredIndex,
    required double lowLimit,
    required double highLimit,
    required double deadband,
    required int timeDelaySeconds,
    required int notificationClass,
    required int eventEnable,
    required int notifyType,
  }) {
    checkNative(
      bacnet_plugin_event_enrollment_configure(
        instance,
        monitoredType,
        monitoredInstance,
        monitoredProperty,
        monitoredIndex,
        lowLimit,
        highLimit,
        deadband,
        timeDelaySeconds,
        notificationClass,
        eventEnable,
        notifyType,
      ),
    );
  }

  /// Enables or disables Audit Log object [instance].
  void configureAuditLog(int instance, {required bool enabled}) {
    checkNative(bacnet_plugin_audit_log_configure(instance, enabled ? 1 : 0));
  }

  /// Configures Audit Reporter object [instance]: which operations it audits,
  /// where it stores records and the recipient it notifies.
  void configureAuditReporter(
    int instance, {
    required int auditLevel,
    required int operations,
    required int auditLogInstance,
    required int maxSendDelaySeconds,
    required ({int deviceId, List<int> mac, int network, List<int> adr})?
    recipient,
  }) {
    checkNative(
      bacnet_plugin_audit_reporter_configure(
        instance,
        auditLevel,
        operations,
        auditLogInstance,
        maxSendDelaySeconds,
      ),
    );
    if (recipient == null) {
      checkNative(
        bacnet_plugin_audit_reporter_set_recipient(
          instance,
          0,
          ffi.nullptr,
          0,
          0,
          ffi.nullptr,
          0,
        ),
      );
      return;
    }
    final mac = recipient.mac;
    final adr = recipient.adr;
    final bytes = Uint8List(mac.length + adr.length)
      ..setAll(0, mac)
      ..setAll(mac.length, adr);
    checkNative(
      _withBytes(
        bytes,
        (data, _) => bacnet_plugin_audit_reporter_set_recipient(
          instance,
          recipient.deviceId,
          mac.isEmpty ? ffi.nullptr : data,
          mac.length,
          recipient.network,
          adr.isEmpty ? ffi.nullptr : data + mac.length,
          adr.length,
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

  /// Sets the password of DeviceCommunicationControl and
  /// ReinitializeDevice ("" accepts requests without one).
  void setPassword(String password) =>
      checkNative(_withString(password, bacnet_plugin_device_set_password));

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
