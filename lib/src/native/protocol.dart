// ignore_for_file: public_member_api_docs
// Messages exchanged between the main isolate and the BACnet worker isolate.
// Internal: not exported by the package.

import 'dart:isolate';
import 'dart:typed_data';

import '../core/types.dart';

/// Startup parameters of the worker isolate.
class WorkerStartup {
  WorkerStartup({
    required this.mainPort,
    required this.interface,
    required this.port,
    required this.deviceInstance,
    required this.apduTimeoutMs,
    required this.apduRetries,
    required this.socketBufferSize,
    required this.strictSourceCheck,
    required this.covScanIntervalMs,
    required this.idlePollMs,
    required this.maxInFlight,
    required this.maxInFlightPerDevice,
    required this.maxQueued,
    required this.bindTimeoutMs,
    required this.offlineAfterTimeouts,
    required this.offlineRetryMs,
    required this.maxSegments,
    required this.logLevel,
  });

  final SendPort mainPort;
  final String? interface;
  final int port;
  final int deviceInstance;
  final int apduTimeoutMs;
  final int apduRetries;
  final int socketBufferSize;
  final bool strictSourceCheck;
  final int covScanIntervalMs;
  final int idlePollMs;
  final int maxInFlight;
  final int maxInFlightPerDevice;
  final int maxQueued;
  final int bindTimeoutMs;
  final int offlineAfterTimeouts;
  final int offlineRetryMs;
  final int maxSegments;
  final BacnetLogLevel logLevel;
}

/// Sent by the worker once the stack is initialized.
class WorkerReady {
  const WorkerReady(this.commandPort, this.version);
  final SendPort commandPort;
  final String version;
}

/// Sent by the worker when initialization fails.
class WorkerFailed {
  const WorkerFailed(this.message);
  final String message;
}

/// Base class of commands; [id] correlates the [CommandResult].
sealed class WorkerCommand {
  const WorkerCommand(this.id);
  final int id;
}

/// How the worker decodes the answer of a confirmed request.
enum AckDecoding {
  none,
  raw,
  readProperty,
  readPropertyMultiple,
  readRange,
  getEventInformation,
  getAlarmSummary,
  createObject,
  atomicReadFile,
  atomicWriteFile,
  privateTransfer,
}

/// A confirmed request with pre-encoded service data.
class ConfirmedRequestCommand extends WorkerCommand {
  const ConfirmedRequestCommand(
    super.id, {
    required this.deviceId,
    required this.service,
    required this.payload,
    required this.timeoutMs,
    this.decoding = AckDecoding.none,
    this.priority = 0,
    this.background = false,
  });

  final int deviceId;
  final int service;
  final Uint8List payload;
  final int timeoutMs;
  final AckDecoding decoding;

  /// Network priority of the NPDU.
  final int priority;

  /// Queued behind normal requests and limited to part of the slots.
  final bool background;
}

/// Drops a queued confirmed request whose caller gave up. No result.
class CancelRequestCommand extends WorkerCommand {
  const CancelRequestCommand(this.requestId) : super(0);

  /// Id of the cancelled [ConfirmedRequestCommand].
  final int requestId;
}

/// An unconfirmed request (broadcast when [deviceId] is null).
class UnconfirmedRequestCommand extends WorkerCommand {
  const UnconfirmedRequestCommand(
    super.id, {
    required this.service,
    required this.payload,
    this.deviceId,
    this.network = 0xFFFF,
    this.mac,
    this.adr = const [],
  });

  final int service;
  final Uint8List payload;
  final int? deviceId;
  final int network;

  /// Sends to this MAC address (empty: a local broadcast that routers
  /// forward to [network] and [adr]) instead of [deviceId].
  final List<int>? mac;
  final List<int> adr;
}

/// Sends a network layer message (a local broadcast when [mac] is empty).
class NetworkMessageCommand extends WorkerCommand {
  const NetworkMessageCommand(
    super.id, {
    required this.messageType,
    required this.payload,
    this.mac = const [],
    this.network = 0,
    this.adr = const [],
    this.vendorId = 0,
  });

  final int messageType;
  final Uint8List payload;
  final List<int> mac;
  final int network;
  final List<int> adr;
  final int vendorId;
}

/// Adds a static address binding.
class BindDeviceCommand extends WorkerCommand {
  const BindDeviceCommand(
    super.id, {
    required this.deviceId,
    required this.host,
    required this.port,
    this.network = 0,
    this.adr = const [],
    this.maxApdu = 1476,
  });

  final int deviceId;
  final String host;
  final int port;
  final int network;
  final List<int> adr;
  final int maxApdu;
}

/// Removes an address binding.
class UnbindDeviceCommand extends WorkerCommand {
  const UnbindDeviceCommand(super.id, this.deviceId);
  final int deviceId;
}

/// Returns the own BACnet/IP address as a list of 6 bytes.
class LocalAddressCommand extends WorkerCommand {
  const LocalAddressCommand(super.id);
}

/// Queries the address binding of a device.
class DeviceBindingCommand extends WorkerCommand {
  const DeviceBindingCommand(super.id, this.deviceId);
  final int deviceId;
}

/// Registers as foreign device with a BBMD.
class RegisterForeignDeviceCommand extends WorkerCommand {
  const RegisterForeignDeviceCommand(
    super.id, {
    required this.host,
    required this.port,
    required this.ttl,
  });

  final String host;
  final int port;
  final int ttl;
}

/// Enables the server role of the local device.
class ServerEnableCommand extends WorkerCommand {
  const ServerEnableCommand(
    super.id, {
    required this.deviceId,
    required this.deviceName,
    this.strings = const {},
    this.vendorId,
    this.password,
  });

  final int deviceId;
  final String deviceName;

  /// Device string properties (property id -> value).
  final Map<int, String> strings;
  final int? vendorId;

  /// Password of DeviceCommunicationControl and ReinitializeDevice; null
  /// refuses both (a random password).
  final String? password;
}

/// Sets the password of DeviceCommunicationControl and ReinitializeDevice
/// (null refuses both).
class SetPasswordCommand extends WorkerCommand {
  const SetPasswordCommand(super.id, this.password);
  final String? password;
}

/// Changes the instance of the local Device object.
class SetDeviceInstanceCommand extends WorkerCommand {
  const SetDeviceInstanceCommand(super.id, this.deviceId);
  final int deviceId;
}

/// Broadcasts an I-Am of the local device.
class SendIAmCommand extends WorkerCommand {
  const SendIAmCommand(super.id);
}

/// Creates a server object and applies initial settings.
class CreateObjectCommand extends WorkerCommand {
  const CreateObjectCommand(
    super.id, {
    required this.objectType,
    required this.instance,
    this.name,
    this.description,
    this.numbers = const {},
    this.stateTexts,
    this.presentValue,
    this.presentValueString,
  });

  final int objectType;
  final int instance;
  final String? name;
  final String? description;

  /// Numeric properties applied after creation (property id -> value).
  final Map<int, double> numbers;
  final List<String>? stateTexts;
  final double? presentValue;
  final String? presentValueString;
}

/// Appends a record to a Trend Log of the server; returns true when
/// recorded (false while the log is disabled).
class TrendLogAppendCommand extends WorkerCommand {
  const TrendLogAppendCommand(
    super.id,
    this.instance,
    this.payload, {
    this.statusFlags = -1,
  });
  final int instance;

  /// Application encoded value.
  final Uint8List payload;

  /// Status flags bits, -1 to leave them out.
  final int statusFlags;
}

/// Lets clients back up and restore the server.
class BackupConfigureCommand extends WorkerCommand {
  const BackupConfigureCommand(
    super.id, {
    required this.files,
    required this.prepare,
    required this.apply,
    required this.failureTimeoutSeconds,
  });
  final List<int> files;
  final bool prepare;
  final bool apply;
  final int failureTimeoutSeconds;
}

/// Sets Backup_And_Restore_State of the server.
class BackupStateCommand extends WorkerCommand {
  const BackupStateCommand(super.id, this.state);
  final int state;
}

/// Replaces the content of a File object of the server.
class SetFileContentCommand extends WorkerCommand {
  const SetFileContentCommand(super.id, this.instance, this.content);
  final int instance;
  final Uint8List content;
}

/// Returns the content of a File object of the server as Uint8List.
class FileContentCommand extends WorkerCommand {
  const FileContentCommand(super.id, this.instance);
  final int instance;
}

/// Sets File_Type and Read_Only of a File object (null keeps them).
class ConfigureFileCommand extends WorkerCommand {
  const ConfigureFileCommand(
    super.id,
    this.instance, {
    this.fileType,
    this.readOnly,
  });
  final int instance;
  final String? fileType;
  final bool? readOnly;
}

/// Deletes a server object.
class DeleteObjectCommand extends WorkerCommand {
  const DeleteObjectCommand(super.id, this.objectType, this.instance);
  final int objectType;
  final int instance;
}

/// Sets a numeric property of a server object locally.
class SetNumberCommand extends WorkerCommand {
  const SetNumberCommand(
    super.id, {
    required this.objectType,
    required this.instance,
    required this.propertyId,
    required this.value,
    this.priority = 16,
  });

  final int objectType;
  final int instance;
  final int propertyId;
  final double value;
  final int priority;
}

/// Sets a text property (name, description, string value) of an object.
class SetTextCommand extends WorkerCommand {
  const SetTextCommand(
    super.id, {
    required this.objectType,
    required this.instance,
    required this.propertyId,
    required this.value,
  });

  final int objectType;
  final int instance;
  final int propertyId;
  final String value;
}

/// Applies many present value updates in one native call.
class SetPresentValuesCommand extends WorkerCommand {
  const SetPresentValuesCommand(super.id, this.packed, this.count);

  /// Packed `bp_present_value_update_t` records (16 bytes each).
  final TransferableTypedData packed;
  final int count;
}

/// Writes an encoded value with WriteProperty semantics.
class LocalWriteCommand extends WorkerCommand {
  const LocalWriteCommand(
    super.id, {
    required this.objectType,
    required this.instance,
    required this.propertyId,
    required this.payload,
    this.arrayIndex = -1,
    this.priority = 16,
  });

  final int objectType;
  final int instance;
  final int propertyId;
  final Uint8List payload;
  final int arrayIndex;
  final int priority;
}

/// Reads a property of a local object.
class LocalReadCommand extends WorkerCommand {
  const LocalReadCommand(
    super.id, {
    required this.objectType,
    required this.instance,
    required this.propertyId,
    this.arrayIndex = -1,
  });

  final int objectType;
  final int instance;
  final int propertyId;
  final int arrayIndex;
}

/// Requests runtime statistics.
class StatsCommand extends WorkerCommand {
  const StatsCommand(super.id);
}

/// Stops the worker and shuts the stack down.
class ShutdownCommand extends WorkerCommand {
  const ShutdownCommand(super.id);
}

/// Result of a command.
class CommandResult {
  const CommandResult(this.id, [this.value]);
  final int id;
  final Object? value;
}

/// Failure of a command. [error] is a BacnetException.
class CommandFailure {
  const CommandFailure(this.id, this.error);
  final int id;
  final Object error;
}
