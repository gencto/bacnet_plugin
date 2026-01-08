import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import '../../../../bacnet_plugin_bindings.g.dart';
import '../../../core/types.dart';
import '../../../models/internal/worker_message.dart';
import '../globals.dart';

/// Handles server initialization requests.
///
/// Sets up the BACnet server with the specified device ID and name.
void handleInitServer(InitServerRequest req) {
  bindings.Device_Set_Object_Instance_Number(req.deviceId);
  final namePtr = req.deviceName.toNativeUtf8();
  bindings.Device_Object_Name_ANSI_Init(namePtr.cast());
  calloc.free(namePtr);

  bindings.Device_Init(ffi.nullptr);

  workerToMainSendPort?.send(const InitSuccessResponse());
  logToMain(
    BacnetLogLevel.info,
    'Server Initialized: Device ${req.deviceId} ("${req.deviceName}")',
  );
}

/// Handles requests to add objects to the BACnet server.
///
/// Creates a new BACnet object with the specified type and instance number.
void handleAddObject(AddObjectRequest req) {
  final data = calloc<BACNET_CREATE_OBJECT_DATA>();
  try {
    data.ref.object_typeAsInt = req.objectType;
    data.ref.object_instance = req.instance;
    if (bindings.Device_Create_Object(data)) {
      logToMain(
        BacnetLogLevel.info,
        'Created Object: Type ${req.objectType}, Instance ${req.instance}',
      );
    } else {
      logToMain(
        BacnetLogLevel.error,
        'Failed to create Object: Type ${req.objectType}, Instance ${req.instance}',
      );
    }
  } finally {
    calloc.free(data);
  }
}

/// Callback handler for WriteProperty requests to the server.
///
/// Intercepts write requests and sends notifications to the main isolate
/// before passing them to the default handler for actual storage.
bool onWriteProperty(ffi.Pointer<BACNET_WRITE_PROPERTY_DATA> wpData) {
  try {
    final len = wpData.ref.application_data_len;
    final bytes = <int>[];
    for (var i = 0; i < len; i++) {
      bytes.add(wpData.ref.application_data[i]);
    }

    workerToMainSendPort?.send(
      WriteNotificationResponse(
        objectType: wpData.ref.object_typeAsInt,
        instance: wpData.ref.object_instance,
        propertyId: wpData.ref.object_propertyAsInt,
        value: bytes,
        index: wpData.ref.array_index,
        priority: wpData.ref.priority,
      ),
    );
  } on Exception catch (e) {
    logToMain(BacnetLogLevel.error, 'Error in onWriteProperty callback', e);
  }

  // Chain to default handler to actually store the value
  return bindings.Device_Write_Property_Local(wpData);
}
