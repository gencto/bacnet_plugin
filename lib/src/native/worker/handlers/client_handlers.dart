import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import '../../../../bacnet_plugin_bindings.g.dart';
import '../../../core/types.dart';
import '../../../models/internal/worker_message.dart';
import '../globals.dart';

/// Handles manual device binding requests.
///
/// Adds a device address binding for direct communication with a specific
/// BACnet device using its IP address and port.
void handleAddBinding(AddDeviceBindingRequest req) {
  final ipStr = req.ip.toNativeUtf8();
  final bipAddr = calloc<BACNET_IP_ADDRESS>();
  final addr = calloc<BACNET_ADDRESS>();
  try {
    if (bindings.bip_get_addr_by_name(ipStr.cast(), bipAddr)) {
      addr.ref.mac_len = 6;
      addr.ref.mac[0] = bipAddr.ref.address[0];
      addr.ref.mac[1] = bipAddr.ref.address[1];
      addr.ref.mac[2] = bipAddr.ref.address[2];
      addr.ref.mac[3] = bipAddr.ref.address[3];
      addr.ref.mac[4] = (req.port >> 8) & 0xFF;
      addr.ref.mac[5] = req.port & 0xFF;
      addr.ref.net = 0;
      addr.ref.len = 0;
      bindings.address_add(req.deviceId, maxAPDU, addr);
      logToMain(
        BacnetLogLevel.info,
        'Manual Binding Added: Device ${req.deviceId} -> ${req.ip}:${req.port}',
      );
    } else {
      logToMain(
        BacnetLogLevel.warning,
        'Failed to resolve IP for binding: ${req.ip}',
      );
    }
  } finally {
    calloc.free(bipAddr);
    calloc.free(addr);
    calloc.free(ipStr);
  }
}

/// Handles COV (Change of Value) subscription requests.
///
/// Subscribes to property changes on a specific BACnet object to receive
/// notifications when values change.
void handleSubscribeCOV(SubscribeCOVRequest req) {
  final ptr = calloc<BACnet_Subscribe_COV_Data>();
  try {
    ptr.ref.monitoredObjectIdentifier.typeAsInt = req.objectType;
    ptr.ref.monitoredObjectIdentifier.instance = req.instance;

    ptr.ref.monitoredProperty.property_identifierAsInt = req.propertyId;
    ptr.ref.monitoredProperty.property_array_index = -1;

    ptr.ref.issueConfirmedNotifications = false;
    ptr.ref.lifetime = 120; // 2 minutes
    ptr.ref.cancellationRequest = false;
    ptr.ref.covSubscribeToProperty = true;
    ptr.ref.covIncrementPresent = false;

    bindings.Send_COV_Subscribe(req.deviceId, ptr);
    logToMain(
      BacnetLogLevel.info,
      'Sent SubscribeCOV to Device ${req.deviceId}',
    );
  } finally {
    calloc.free(ptr);
  }
}

/// Handles foreign device registration (FDR) requests.
///
/// Registers this device with a BBMD (BACnet Broadcast Management Device)
/// to enable communication across subnets.
void handleRegisterFDR(RegisterFdrRequest req) {
  final ipStr = req.ip.toNativeUtf8();
  final bbmdAddr = calloc<BACNET_IP_ADDRESS>();
  try {
    bindings.bip_get_addr_by_name(ipStr.cast(), bbmdAddr);
    bbmdAddr.ref.port = req.port;
    bindings.bvlc_register_with_bbmd(bbmdAddr, req.ttl);
  } finally {
    calloc.free(bbmdAddr);
    calloc.free(ipStr);
  }
}

/// Handles Who-Is broadcast requests.
///
/// Sends a Who-Is message to discover BACnet devices on the network within
/// the specified device ID range.
void handleWhoIs(WhoIsRequest req) {
  bindings.Send_WhoIs_Global(req.lowLimit, req.highLimit);
}

/// Handles ReadProperty requests.
///
/// Sends a request to read a single property value from a BACnet object.
void handleReadProp(ReadPropertyRequest req) {
  logToMain(
    BacnetLogLevel.info,
    '📤 Sending ReadProperty to device ${req.deviceId}, prop ${req.propertyId}',
  );

  final invokeId = bindings.Send_Read_Property_Request(
    req.deviceId,
    BACnetObjectType.fromValue(req.objectType),
    req.instance,
    BACnetPropertyIdentifier.fromValue(req.propertyId),
    req.arrayIndex,
  );

  logToMain(BacnetLogLevel.info, '📤 ReadProperty sent, invokeId: $invokeId');

  workerToMainSendPort?.send(
    ReadPropertySentResponse(trackingId: req.trackingId, invokeId: invokeId),
  );
}

/// Handles WriteProperty requests.
///
/// Sends a request to write a value to a specific property of a BACnet object.
void handleWriteProp(WritePropertyRequest req) {
  final ptr = calloc<BACNET_APPLICATION_DATA_VALUE>();
  try {
    final value = req.value;
    final tag = req.tag;
    ptr.ref.tag = tag;
    ptr.ref.context_specific = false;
    switch (tag) {
      case 1:
        ptr.ref.type.Boolean = value as bool;
        break;
      case 4:
        ptr.ref.type.Real = (value as num).toDouble();
        break;
      case 2:
        ptr.ref.type.Unsigned_Int = value as int;
        break;
    }

    bindings.Send_Write_Property_Request(
      req.deviceId,
      BACnetObjectType.fromValue(req.objectType),
      req.instance,
      BACnetPropertyIdentifier.fromValue(req.propertyId),
      ptr,
      req.priority,
      req.priority == 16 ? -1 : req.priority,
    );
  } finally {
    calloc.free(ptr);
  }
}

/// Handles ReadPropertyMultiple (RPM) requests.
///
/// Sends a request to read multiple properties from multiple objects in a
/// single transaction for improved efficiency.
void handleReadPropMultiple(ReadPropertyMultipleRequest req) {
  logToMain(
    BacnetLogLevel.info,
    '🔵 RPM Handler: Starting for device ${req.deviceId} with ${req.readAccessSpecs.length} specs',
  );

  // We need to keep track of allocated pointers to free them later
  final allocatedPointers = <ffi.Pointer>[];

  try {
    ffi.Pointer<BACNET_READ_ACCESS_DATA> headReadAccessData = ffi.nullptr;
    ffi.Pointer<BACNET_READ_ACCESS_DATA> currentReadAccessData = ffi.nullptr;

    for (final spec in req.readAccessSpecs) {
      final radPtr = calloc<BACNET_READ_ACCESS_DATA>();
      allocatedPointers.add(radPtr);

      if (headReadAccessData == ffi.nullptr) {
        headReadAccessData = radPtr;
        currentReadAccessData = radPtr;
      } else {
        currentReadAccessData.ref.next = radPtr;
        currentReadAccessData = radPtr;
      }

      radPtr.ref.object_typeAsInt = spec.objectIdentifier.type;
      radPtr.ref.object_instance = spec.objectIdentifier.instance;
      radPtr.ref.next = ffi.nullptr;

      ffi.Pointer<BACNET_PROPERTY_REFERENCE> headPropRef = ffi.nullptr;
      ffi.Pointer<BACNET_PROPERTY_REFERENCE> currentPropRef = ffi.nullptr;

      for (final prop in spec.properties) {
        final propPtr = calloc<BACNET_PROPERTY_REFERENCE>();
        allocatedPointers.add(propPtr);

        if (headPropRef == ffi.nullptr) {
          headPropRef = propPtr;
          currentPropRef = propPtr;
        } else {
          currentPropRef.ref.next = propPtr;
          currentPropRef = propPtr;
        }

        propPtr.ref.propertyIdentifierAsInt = prop.propertyIdentifier;
        propPtr.ref.propertyArrayIndex = prop.propertyArrayIndex;
        propPtr.ref.next = ffi.nullptr;
      }

      radPtr.ref.listOfProperties = headPropRef;
    }

    final pduBuffer = calloc<ffi.Uint8>(maxAPDU);
    allocatedPointers.add(pduBuffer);

    logToMain(
      BacnetLogLevel.info,
      '🔵 RPM Handler: Calling native Send_Read_Property_Multiple_Request for device ${req.deviceId}',
    );

    final invokeId = bindings.Send_Read_Property_Multiple_Request(
      pduBuffer,
      maxAPDU,
      req.deviceId,
      headReadAccessData,
    );

    logToMain(
      BacnetLogLevel.info,
      '🔵 RPM Handler: Native call returned invokeId: $invokeId',
    );

    if (invokeId > 0) {
      logToMain(
        BacnetLogLevel.info,
        '✅ RPM Handler: Sending ReadPropertySentResponse (trackingId: ${req.trackingId}, invokeId: $invokeId)',
      );
      workerToMainSendPort?.send(
        ReadPropertySentResponse(
          trackingId: req.trackingId ?? 0,
          invokeId: invokeId,
        ),
      );
    } else {
      logToMain(
        BacnetLogLevel.error,
        'Failed to send RPM request to device ${req.deviceId}',
      );
      workerToMainSendPort?.send(
        const ErrorResponse('Failed to send RPM request'),
      );
    }
  } on Exception catch (e, st) {
    logToMain(BacnetLogLevel.error, 'Exception in RPM handler', e, st);
    workerToMainSendPort?.send(ErrorResponse('RPM Exception: $e'));
  } finally {
    for (final ptr in allocatedPointers) {
      calloc.free(ptr);
    }
  }
}

/// Handles WritePropertyMultiple (WPM) requests.
///
/// Sends a request to write multiple properties to multiple objects in a
/// single transaction for improved efficiency.
void handleWritePropMultiple(WritePropertyMultipleRequest req) {
  final allocatedPointers = <ffi.Pointer>[];

  try {
    ffi.Pointer<BACNET_WRITE_ACCESS_DATA> headWriteAccessData = ffi.nullptr;
    ffi.Pointer<BACNET_WRITE_ACCESS_DATA> currentWriteAccessData = ffi.nullptr;

    for (final spec in req.writeAccessSpecs) {
      final wadPtr = calloc<BACNET_WRITE_ACCESS_DATA>();
      allocatedPointers.add(wadPtr);

      if (headWriteAccessData == ffi.nullptr) {
        headWriteAccessData = wadPtr;
        currentWriteAccessData = wadPtr;
      } else {
        currentWriteAccessData.ref.next = wadPtr;
        currentWriteAccessData = wadPtr;
      }

      wadPtr.ref.object_typeAsInt = spec.objectIdentifier.type;
      wadPtr.ref.object_instance = spec.objectIdentifier.instance;
      wadPtr.ref.next = ffi.nullptr;

      ffi.Pointer<BACNET_PROPERTY_VALUE> headPropVal = ffi.nullptr;
      ffi.Pointer<BACNET_PROPERTY_VALUE> currentPropVal = ffi.nullptr;

      for (final prop in spec.listOfProperties) {
        final propValPtr = calloc<BACNET_PROPERTY_VALUE>();
        allocatedPointers.add(propValPtr);

        if (headPropVal == ffi.nullptr) {
          headPropVal = propValPtr;
          currentPropVal = propValPtr;
        } else {
          currentPropVal.ref.next = propValPtr;
          currentPropVal = propValPtr;
        }

        propValPtr.ref.propertyIdentifierAsInt = prop.propertyIdentifier;
        propValPtr.ref.propertyArrayIndex = prop.propertyArrayIndex;
        propValPtr.ref.priority = prop.priority;
        propValPtr.ref.next = ffi.nullptr;

        // Set value
        // The value structure is embedded in BACNET_PROPERTY_VALUE as 'value'
        // type BACNET_APPLICATION_DATA_VALUE
        final appData = propValPtr.ref.value;
        final value = prop.value;
        final tag = prop.tag; // Ensure BacnetPropertyValue model has tag/value

        appData.tag = tag;
        appData.context_specific = false;

        switch (tag) {
          case 1: // Boolean
            appData.type.Boolean = value as bool;
            break;
          case 2: // Unsigned Int
            appData.type.Unsigned_Int = value as int;
            break;
          case 3: // Signed Int
            appData.type.Signed_Int = value as int;
            break;
          case 4: // Real
            appData.type.Real = (value as num).toDouble();
            break;
          case 9: // Enumerated
            appData.type.Enumerated = value as int;
            break;
          // Add more types as needed (String, Object ID, etc.)
          default:
            logToMain(BacnetLogLevel.warning, 'Unsupported WPM tag: $tag');
        }
      }
      wadPtr.ref.listOfProperties = headPropVal;
    }

    final invokeId = bindings.bacnet_plugin_send_write_property_multiple(
      req.deviceId,
      headWriteAccessData,
    );

    if (invokeId > 0) {
      workerToMainSendPort?.send(
        WritePropertyMultipleSentResponse(
          trackingId: req.trackingId ?? 0,
          invokeId: invokeId,
        ),
      );
    } else {
      logToMain(
        BacnetLogLevel.error,
        'Failed to send WPM request to device ${req.deviceId}',
      );
      workerToMainSendPort?.send(
        const ErrorResponse('Failed to send WPM request'),
      );
    }
  } on Exception catch (e, st) {
    logToMain(BacnetLogLevel.error, 'Exception in WPM handler', e, st);
    workerToMainSendPort?.send(ErrorResponse('WPM Exception: $e'));
  } finally {
    for (final ptr in allocatedPointers) {
      calloc.free(ptr);
    }
  }
}

/// Handles ReadRange requests.
///
/// Sends a ReadRange request to a device (e.g. for TrendLogs).
void handleReadRange(ReadRangeRequest req) {
  final allocatedPointers = <ffi.Pointer>[];
  try {
    final rrData = calloc<BACNET_READ_RANGE_DATA>();
    allocatedPointers.add(rrData);

    rrData.ref.object_typeAsInt = req.objectType;
    rrData.ref.object_instance = req.instance;
    rrData.ref.object_propertyAsInt = req.propertyId;
    rrData.ref.array_index = req.arrayIndex; // -1 for all
    rrData.ref.application_data = ffi.nullptr;
    rrData.ref.application_data_len = 0;

    // ResultFlags is BitString. Init to empty?
    // We are SENDING a request, so ResultFlags is ignored (it's output).
    // RequestType: 1=Position, 2=Sequence, 3=Time?
    // Defines are in readrange.h: RR_BY_POSITION=1, RR_BY_SEQUENCE=2, RR_BY_TIME=4

    rrData.ref.RequestType = req.requestType;
    rrData.ref.ItemCount = req.count > 0
        ? req.count
        : 0; // count is unsigned 32
    rrData.ref.Count = req.count; // Signed count for direction

    // Set Union Range based on type
    if (req.requestType == 1) {
      // Position
      rrData.ref.Range.RefIndex = req.reference as int;
    } else if (req.requestType == 2) {
      // Sequence
      rrData.ref.Range.RefSeqNum = req.reference as int;
    } else if (req.requestType == 4) {
      // Time
      // Need to parse DateTime which is hard. Assuming Sequence for TrendLogs usually.
      // If time provided, we need to populate RefTime (BACNET_DATE_TIME).
      // Leaving Time unsupported for this iteration unless critical.
    }

    final invokeId = bindings.bacnet_plugin_send_read_range_request(
      req.deviceId,
      rrData,
    );

    if (invokeId > 0) {
      workerToMainSendPort?.send(
        ReadPropertySentResponse(
          trackingId: req.trackingId ?? 0,
          invokeId: invokeId,
        ),
      );
    } else {
      logToMain(
        BacnetLogLevel.error,
        'Failed to send ReadRange request to device ${req.deviceId}',
      );
      workerToMainSendPort?.send(
        const ErrorResponse('Failed to send ReadRange request'),
      );
    }
  } on Exception catch (e, s) {
    logToMain(BacnetLogLevel.error, 'ReadRange Handle Error', e, s);
    workerToMainSendPort?.send(ErrorResponse('ReadRange Error: $e'));
  } finally {
    for (final ptr in allocatedPointers) {
      calloc.free(ptr);
    }
  }
}
