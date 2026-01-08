import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../../bacnet_plugin_bindings.g.dart';
import '../../core/types.dart';
import '../../models/internal/worker_message.dart';
import 'callbacks.dart';
import 'globals.dart';
import 'handlers/client_handlers.dart';
import 'handlers/server_handlers.dart';

/// Entry point for the BACnet worker isolate.
///
/// This function runs in a separate isolate and handles all low-level BACnet
/// protocol operations, FFI calls, and network polling. It sets up callback
/// handlers for various BACnet services and processes requests from the main isolate.
void bacnetWorkerEntryPoint(Map<String, dynamic> args) {
  workerToMainSendPort = args['sendPort'] as SendPort;
  final interface = args['interface'] as String?;
  final port = args['port'] as int;
  final receivePort = ReceivePort();

  try {
    var libraryPath = Platform.isWindows
        ? 'bacnet_plugin.dll'
        : 'libbacnet_plugin.so';
    if (Platform.isMacOS) libraryPath = 'libbacnet_plugin.dylib';

    bindings = BacnetBindings(ffi.DynamicLibrary.open(libraryPath));
    bindings.bip_set_port(port);

    final ifnamePtr = interface?.toNativeUtf8();
    final success = bindings.bacnet_plugin_safe_bip_init(
      ifnamePtr?.cast() ?? ffi.nullptr,
    );
    if (ifnamePtr != null) calloc.free(ifnamePtr);

    if (!success) {
      workerToMainSendPort?.send(
        const ErrorResponse('Failed to initialize BACnet/IP'),
      );
      return;
    }

    // Keep callables alive to prevent GC
    final keepAlive = <Object>[];

    final iamCallable =
        ffi.NativeCallable<unconfirmed_functionFunction>.isolateLocal(onIAm);
    keepAlive.add(iamCallable);
    bindings.apdu_set_unconfirmed_handler(
      BACnet_Unconfirmed_Service_Choice.SERVICE_UNCONFIRMED_I_AM,
      iamCallable.nativeFunction,
    );

    final rpAckCallable =
        ffi.NativeCallable<confirmed_ack_functionFunction>.isolateLocal(
          onReadPropertyAck,
        );
    keepAlive.add(rpAckCallable);
    bindings.apdu_set_confirmed_ack_handler(
      BACnet_Confirmed_Service_Choice.SERVICE_CONFIRMED_READ_PROPERTY,
      rpAckCallable.nativeFunction,
    );

    // RPM Ack Handler
    final rpmAckCallable =
        ffi.NativeCallable<confirmed_ack_functionFunction>.isolateLocal(
          onReadPropertyMultipleAck,
        );
    keepAlive.add(rpmAckCallable);
    bindings.apdu_set_confirmed_ack_handler(
      BACnet_Confirmed_Service_Choice.SERVICE_CONFIRMED_READ_PROP_MULTIPLE,
      rpmAckCallable.nativeFunction,
    );

    // COV Notification Handlers
    final covUnconfirmedCallable =
        ffi.NativeCallable<unconfirmed_functionFunction>.isolateLocal(
          onUnconfirmedCOVNotification,
        );
    keepAlive.add(covUnconfirmedCallable);
    bindings.apdu_set_unconfirmed_handler(
      BACnet_Unconfirmed_Service_Choice.SERVICE_UNCONFIRMED_COV_NOTIFICATION,
      covUnconfirmedCallable.nativeFunction,
    );

    final covConfirmedCallable =
        ffi.NativeCallable<confirmed_functionFunction>.isolateLocal(
          onConfirmedCOVNotification,
        );
    keepAlive.add(covConfirmedCallable);
    bindings.apdu_set_confirmed_handler(
      BACnet_Confirmed_Service_Choice.SERVICE_CONFIRMED_COV_NOTIFICATION,
      covConfirmedCallable.nativeFunction,
    );

    // Write Property Handler (Server)
    final writePropCallable =
        ffi.NativeCallable<write_property_functionFunction>.isolateLocal(
          onWriteProperty,
          exceptionalReturn: false,
        );
    keepAlive.add(writePropCallable);
    bindings.Device_Write_Property_Store_Callback_Set(
      writePropCallable.nativeFunction,
    );

    final srcAddressBuffer = calloc<BACNET_ADDRESS>();
    final pduBuffer = calloc<ffi.Uint8>(maxAPDU);

    workerToMainSendPort?.send(receivePort.sendPort);

    Timer.periodic(const Duration(milliseconds: 10), (_) {
      try {
        int pduLen = bindings.bacnet_plugin_safe_bip_receive(
          srcAddressBuffer,
          pduBuffer,
          maxAPDU,
          5,
        );
        if (pduLen > 0) {
          logToMain(BacnetLogLevel.debug, 'Rx PDU: $pduLen bytes');
          bindings.bacnet_plugin_safe_npdu_handler(
            srcAddressBuffer,
            pduBuffer,
            pduLen,
          );
        }
        bindings.tsm_timer_milliseconds(
          DateTime.now().millisecondsSinceEpoch & 0xFFFFFFFF,
        );
      } on Exception {
        /* suppress */
      }
    });

    receivePort.listen((message) {
      logToMain(
        BacnetLogLevel.info,
        '🟡 Worker: Received message of type: ${message.runtimeType}',
      );
      if (message is WorkerRequest) {
        switch (message) {
          case WhoIsRequest():
            handleWhoIs(message);
            break;
          case ReadPropertyRequest():
            handleReadProp(message);
            break;
          case WritePropertyRequest():
            handleWriteProp(message);
            break;
          case RegisterFdrRequest():
            handleRegisterFDR(message);
            break;
          case AddDeviceBindingRequest():
            handleAddBinding(message);
            break;
          case SubscribeCOVRequest():
            handleSubscribeCOV(message);
            break;
          case InitServerRequest():
            handleInitServer(message);
            break;
          case AddObjectRequest():
            handleAddObject(message);
            break;
          case ReadPropertyMultipleRequest():
            logToMain(
              BacnetLogLevel.info,
              '🔴 Worker: Received ReadPropertyMultipleRequest for device ${message.deviceId}',
            );
            handleReadPropMultiple(message);
            break;
          case WritePropertyMultipleRequest():
            handleWritePropMultiple(message);
            break;
          case ReadRangeRequest():
            handleReadRange(message);
            break;
        }
      }
    });

    // ReadRange Ack Handler
    final readRangeAckCallable =
        ffi.NativeCallable<confirmed_ack_functionFunction>.isolateLocal(
          onReadRangeAck,
        );
    keepAlive.add(readRangeAckCallable);
    bindings.apdu_set_confirmed_ack_handler(
      BACnet_Confirmed_Service_Choice.SERVICE_CONFIRMED_READ_RANGE,
      readRangeAckCallable.nativeFunction,
    );
  } on Exception catch (e, st) {
    workerToMainSendPort?.send(ErrorResponse('Worker exception: $e\n$st'));
  }
}
