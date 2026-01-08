import 'dart:ffi' as ffi;

import 'package:bacnet_plugin/src/native/worker/read_range_decoder.dart';
import 'package:bacnet_plugin/src/native/worker/rpm_decoder.dart';

import '../../../bacnet_plugin_bindings.g.dart';
import '../../core/types.dart';
import '../../models/internal/worker_message.dart';
import 'decoder.dart';
import 'globals.dart';

/// Callback handler for I-Am service responses.
///
/// Processes incoming I-Am messages from BACnet devices announcing their presence
/// on the network. Extracts the device ID and forwards it to the main isolate.
void onIAm(
  ffi.Pointer<ffi.Uint8> serviceRequest,
  int len,
  ffi.Pointer<BACNET_ADDRESS> src,
) {
  int deviceId = -1;
  try {
    if (len > 0) {
      int offset = 0;
      final tagByte = serviceRequest[offset++];
      final tagNumber = (tagByte & 0xF0) >> 4;
      final lenValueType = tagByte & 0x07;

      if (tagNumber == 12) {
        // Object ID
        int contentLen = lenValueType;
        if (contentLen == 5) contentLen = serviceRequest[offset++];
        int val = 0;
        for (int i = 0; i < contentLen; i++) {
          val = (val << 8) | serviceRequest[offset++];
        }
        deviceId = val & 0x3FFFFF;
      }
    }
  } on Exception catch (e) {
    logToMain(BacnetLogLevel.error, 'I-Am Decode Error', e);
  }

  workerToMainSendPort?.send(
    IAmResponse(
      deviceId: deviceId,
      len: len,
      mac: [for (var i = 0; i < src.ref.mac_len; i++) src.ref.mac[i]],
      net: src.ref.net,
    ),
  );
}

/// Callback handler for ReadProperty acknowledgment responses.
///
/// Decodes property values from ReadProperty responses and forwards them to
/// the main isolate with the corresponding invoke ID.
void onReadPropertyAck(
  ffi.Pointer<ffi.Uint8> serviceRequest,
  int serviceLen,
  ffi.Pointer<BACNET_ADDRESS> src,
  ffi.Pointer<BACNET_CONFIRMED_SERVICE_ACK_DATA> serviceData,
) {
  dynamic decodedValue;
  try {
    int offset = 0;
    bool found = false;
    while (offset < serviceLen) {
      if (serviceRequest[offset] == 0x3E) {
        offset++;
        found = true;
        break;
      }
      offset++;
    }

    if (found && offset < serviceLen) {
      decodedValue = decodeApplicationData(serviceRequest, serviceLen, offset);
    } else {
      decodedValue = 'No Value Tag Found';
    }
  } on Exception catch (e) {
    decodedValue = 'Decode Error: $e';
  }

  workerToMainSendPort?.send(
    ReadPropertyAckResponse(
      invokeId: serviceData.ref.invoke_id,
      value: decodedValue,
    ),
  );
}

/// Callback handler for unconfirmed COV (Change of Value) notifications.
///
/// Processes COV notifications that do not require acknowledgment.
void onUnconfirmedCOVNotification(
  ffi.Pointer<ffi.Uint8> serviceRequest,
  int serviceLen,
  ffi.Pointer<BACNET_ADDRESS> src,
) {
  _processCOVNotification(serviceRequest, serviceLen);
}

/// Callback handler for confirmed COV (Change of Value) notifications.
///
/// Processes COV notifications that require acknowledgment from the client.
void onConfirmedCOVNotification(
  ffi.Pointer<ffi.Uint8> serviceRequest,
  int serviceLen,
  ffi.Pointer<BACNET_ADDRESS> src,
  ffi.Pointer<BACNET_CONFIRMED_SERVICE_DATA> serviceData,
) {
  _processCOVNotification(serviceRequest, serviceLen);
}

void _processCOVNotification(
  ffi.Pointer<ffi.Uint8> serviceRequest,
  int serviceLen,
) {
  try {
    int offset = 0;
    int monitoredTypeId = -1;
    int monitoredInst = -1;

    // Heuristic: Search for Monitored Object ID (Context Tag 2 -> 0x2C)
    while (offset < serviceLen - 5) {
      int tag = serviceRequest[offset];
      if (tag == 0x2C) {
        offset++;
        int val = 0;
        for (int i = 0; i < 4; i++) {
          val = (val << 8) | serviceRequest[offset++];
        }
        monitoredTypeId = (val >> 22) & 0x3FF;
        monitoredInst = val & 0x3FFFFF;
        break;
      }
      offset++;
    }

    workerToMainSendPort?.send(
      COVNotificationResponse(
        objectType: monitoredTypeId,
        instance: monitoredInst,
        timestamp: DateTime.now().toIso8601String(),
      ),
    );
    logToMain(
      BacnetLogLevel.info,
      'Rx COV Notification for $monitoredTypeId:$monitoredInst',
    );
  } on Exception catch (e) {
    logToMain(BacnetLogLevel.error, 'COV Decode Error', e);
  }
}

/// Callback handler for ReadPropertyMultiple acknowledgment responses.
///
/// Decodes multiple property values from RPM responses and forwards them to
/// the main isolate with the corresponding invoke ID.
void onReadPropertyMultipleAck(
  ffi.Pointer<ffi.Uint8> serviceRequest,
  int serviceLen,
  ffi.Pointer<BACNET_ADDRESS> src,
  ffi.Pointer<BACNET_CONFIRMED_SERVICE_ACK_DATA> serviceData,
) {
  try {
    final decoded = RPMDecoder.decode(serviceRequest, serviceLen);

    if (decoded.isNotEmpty) {
      workerToMainSendPort?.send(
        ReadPropertyMultipleAckResponse(
          invokeId: serviceData.ref.invoke_id,
          values: decoded,
        ),
      );
    } else {
      logToMain(
        BacnetLogLevel.warning,
        'Rx RPM Ack Empty or Failed Decode (Len $serviceLen)',
      );
      // Ensure we send something back so the Future completes
      workerToMainSendPort?.send(
        ReadPropertyMultipleAckResponse(
          invokeId: serviceData.ref.invoke_id,
          values: const <String, dynamic>{},
        ),
      );
    }
  } on Exception catch (e, st) {
    logToMain(BacnetLogLevel.error, 'RPM Ack Handler Error', e, st);
  }
}

/// Callback handler for ReadRange acknowledgment responses.
///
/// Decodes the ReadRange response including ResultFlags, ItemCount, and Data.
void onReadRangeAck(
  ffi.Pointer<ffi.Uint8> serviceRequest,
  int serviceLen,
  ffi.Pointer<BACNET_ADDRESS> src,
  ffi.Pointer<BACNET_CONFIRMED_SERVICE_ACK_DATA> serviceData,
) {
  try {
    // int offset = 0; // Unused
    int resultFlags = 0;
    int itemCount = 0;
    final items = <dynamic>[];

    // ReadRangeAck has context tags 0..6
    // We need to jump over headers to find ItemData (Tag 6) or extract metadata

    // 0: ObjectIdentifier (Optional? No, mandatory in Ack?)
    // ASHRAE 135:
    // objectIdentifier [0]
    // propertyIdentifier [1]
    // propertyArrayIndex [2] OPTIONAL
    // resultFlags [3] BACnetResultFlags
    // itemCount [4] Unsigned
    // firstSequenceNumber [5] OPTIONAL
    // itemData [6] List of property values

    final decoded = ReadRangeDecoder.decode(serviceRequest, serviceLen);
    resultFlags = decoded['flags'] as int;
    itemCount = decoded['count'] as int;
    if (decoded['data'] is List) {
      items.addAll(decoded['data'] as List);
    }

    // Skip manual parsing loop
    // offset = serviceLen; // Stop loop

    workerToMainSendPort?.send(
      ReadRangeAckResponse(
        invokeId: serviceData.ref.invoke_id,
        resultFlags: resultFlags,
        itemCount: itemCount,
        data: items,
      ),
    );
  } on Exception catch (e, st) {
    logToMain(BacnetLogLevel.error, 'ReadRange Ack Handler Error', e, st);
  }
}
