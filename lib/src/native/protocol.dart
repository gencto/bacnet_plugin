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
  });

  final int service;
  final Uint8List payload;
  final int? deviceId;
  final int network;
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

/// Queries the address binding of a device.
/// Returns the own BACnet/IP address as a list of 6 bytes.
class LocalAddressCommand extends WorkerCommand {
  const LocalAddressCommand(super.id);
}

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
  });

  final int deviceId;
  final String deviceName;

  /// Device string properties (property id -> value).
  final Map<int, String> strings;
  final int? vendorId;
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
