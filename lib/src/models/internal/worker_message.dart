import '../rpm_models.dart';
import '../wpm_models.dart';

/// Base class for all requests sent from main isolate to worker isolate.
sealed class WorkerRequest {
  const WorkerRequest();
}

/// Base class for all responses sent from worker isolate to main isolate.
sealed class WorkerResponse {
  const WorkerResponse();
}

// --- Requests (Main -> Worker) ---

/// Request to broadcast a Who-Is message to discover BACnet devices.
class WhoIsRequest extends WorkerRequest {
  /// Lower device ID limit (-1 for no limit).
  final int lowLimit;

  /// Upper device ID limit (-1 for no limit).
  final int highLimit;

  /// Creates a Who-Is request.
  const WhoIsRequest({this.lowLimit = -1, this.highLimit = -1});
}

/// Request to read a single property from a BACnet object.
class ReadPropertyRequest extends WorkerRequest {
  /// Internal tracking ID for request-response matching.
  final int trackingId;

  /// Target device ID.
  final int deviceId;

  /// BACnet object type.
  final int objectType;

  /// Object instance number.
  final int instance;

  /// Property identifier to read.
  final int propertyId;

  /// Array index (-1 for entire property).
  final int arrayIndex;

  /// Creates a ReadProperty request.
  const ReadPropertyRequest({
    required this.trackingId,
    required this.deviceId,
    required this.objectType,
    required this.instance,
    required this.propertyId,
    this.arrayIndex = -1,
  });
}

/// Request to write a value to a BACnet object property.
class WritePropertyRequest extends WorkerRequest {
  /// Target device ID.
  final int deviceId;

  /// BACnet object type.
  final int objectType;

  /// Object instance number.
  final int instance;

  /// Property identifier to write.
  final int propertyId;

  /// Value to write.
  final dynamic value;

  /// Write priority (16 = no priority).
  final int priority;

  /// BACnet application tag for the value.
  final int tag;

  /// Creates a WriteProperty request.
  const WritePropertyRequest({
    required this.deviceId,
    required this.objectType,
    required this.instance,
    required this.propertyId,
    required this.value,
    this.priority = 16,
    this.tag = 4,
  });
}

/// Request to register as a foreign device with a BBMD.
class RegisterFdrRequest extends WorkerRequest {
  /// BBMD IP address.
  final String ip;

  /// BBMD port.
  final int port;

  /// Registration time-to-live in seconds.
  final int ttl;

  /// Creates a foreign device registration request.
  const RegisterFdrRequest({
    required this.ip,
    this.port = 47808,
    this.ttl = 120,
  });
}

/// Request to manually add a device address binding.
class AddDeviceBindingRequest extends WorkerRequest {
  /// Device ID to bind.
  final int deviceId;

  /// Device IP address.
  final String ip;

  /// Device BACnet port.
  final int port;

  /// Creates a device binding request.
  const AddDeviceBindingRequest({
    required this.deviceId,
    required this.ip,
    this.port = 47808,
  });
}

/// Request to subscribe to Change of Value (COV) notifications.
class SubscribeCOVRequest extends WorkerRequest {
  /// Target device ID.
  final int deviceId;

  /// BACnet object type to monitor.
  final int objectType;

  /// Object instance to monitor.
  final int instance;

  /// Property to monitor.
  final int propertyId;

  /// Creates a COV subscription request.
  const SubscribeCOVRequest({
    required this.deviceId,
    required this.objectType,
    required this.instance,
    this.propertyId = 65, // default prop PresentValue
  });
}

/// Request to initialize the BACnet server.
class InitServerRequest extends WorkerRequest {
  /// Server device ID.
  final int deviceId;

  /// Server device name.
  final String deviceName;

  /// Creates a server initialization request.
  const InitServerRequest(this.deviceId, this.deviceName);
}

/// Request to add an object to the BACnet server.
class AddObjectRequest extends WorkerRequest {
  /// Object type to create.
  final int objectType;

  /// Object instance number.
  final int instance;

  /// Creates an add object request.
  const AddObjectRequest(this.objectType, this.instance);
}

/// Request to read multiple properties from multiple objects.
class ReadPropertyMultipleRequest extends WorkerRequest {
  /// Creates a ReadPropertyMultiple request.
  const ReadPropertyMultipleRequest({
    required this.deviceId,
    required this.readAccessSpecs,
    this.trackingId,
  });

  /// Target device ID.
  final int deviceId;

  /// List of object/property specifications to read.
  final List<BacnetReadAccessSpecification> readAccessSpecs;

  /// Optional tracking ID.
  final int? trackingId;
}

/// Request to write multiple values to multiple objects.
class WritePropertyMultipleRequest extends WorkerRequest {
  /// Creates a WritePropertyMultiple request.
  const WritePropertyMultipleRequest({
    required this.deviceId,
    required this.writeAccessSpecs,
    this.trackingId,
  });

  /// Target device ID.
  final int deviceId;

  /// List of object/property/value specifications to write.
  final List<BacnetWriteAccessSpecification> writeAccessSpecs;

  /// Optional tracking ID.
  final int? trackingId;
}

// --- Responses (Worker -> Main) ---

/// Response indicating successful server initialization.
class InitSuccessResponse extends WorkerResponse {
  /// Creates a successful initialization response.
  const InitSuccessResponse();
}

/// Response indicating an error occurred in the worker.
class ErrorResponse extends WorkerResponse {
  /// Error message.
  final String error;

  /// Creates an error response.
  const ErrorResponse(this.error);
}

/// Response containing a log message from the worker.
class LogResponse extends WorkerResponse {
  /// Log level index.
  final int levelIndex;

  /// Log message.
  final String message;

  /// Error object string if present.
  final String? errorObj;

  /// Stack trace string if present.
  final String? stackTrace;

  /// Creates a log response.
  const LogResponse({
    required this.levelIndex,
    required this.message,
    this.errorObj,
    this.stackTrace,
  });
}

/// Response indicating a ReadProperty request was sent successfully.
class ReadPropertySentResponse extends WorkerResponse {
  /// Original tracking ID.
  final int trackingId;

  /// Invoke ID assigned by the stack.
  final int invokeId;

  /// Creates a ReadProperty sent confirmation.
  const ReadPropertySentResponse({
    required this.trackingId,
    required this.invokeId,
  });
}

/// Response containing a ReadProperty acknowledgment.
class ReadPropertyAckResponse extends WorkerResponse {
  /// Invoke ID from the request.
  final int invokeId;

  /// Decoded property value.
  final dynamic value;

  /// Creates a ReadProperty acknowledgment response.
  const ReadPropertyAckResponse({required this.invokeId, this.value});
}

/// Response containing a ReadPropertyMultiple acknowledgment.
class ReadPropertyMultipleAckResponse extends WorkerResponse {
  /// Invoke ID from the request.
  final int invokeId;

  /// Map of object IDs to property values.
  final dynamic values;

  /// Creates a ReadPropertyMultiple acknowledgment response.
  const ReadPropertyMultipleAckResponse({required this.invokeId, this.values});
}

/// Response indicating a WritePropertyMultiple request was sent successfully.
class WritePropertyMultipleSentResponse extends WorkerResponse {
  /// Original tracking ID.
  final int trackingId;

  /// Invoke ID assigned by the stack.
  final int invokeId;

  /// Creates a WritePropertyMultiple sent confirmation.
  const WritePropertyMultipleSentResponse({
    required this.trackingId,
    required this.invokeId,
  });
}

/// Response containing an I-Am announcement from a device.
class IAmResponse extends WorkerResponse {
  /// Announced device ID.
  final int deviceId;

  /// Network number.
  final int net;

  /// MAC address bytes.
  final List<int> mac;

  /// Message length.
  final int len;

  /// Creates an I-Am response.
  const IAmResponse({
    required this.deviceId,
    required this.net,
    required this.mac,
    required this.len,
  });
}

/// Response containing a Change of Value notification.
class COVNotificationResponse extends WorkerResponse {
  /// Object type that changed.
  final int objectType;

  /// Object instance that changed.
  final int instance;

  /// Timestamp of the notification.
  final String timestamp;

  /// Source device ID (-1 if unknown).
  final int deviceId;

  /// Creates a COV notification response.
  const COVNotificationResponse({
    required this.objectType,
    required this.instance,
    required this.timestamp,
    this.deviceId = -1,
  });
}

/// Response containing a WriteProperty notification from the server.
class WriteNotificationResponse extends WorkerResponse {
  /// Object type written to.
  final int objectType;

  /// Object instance written to.
  final int instance;

  /// Property identifier written.
  final int propertyId;

  /// Written value (null if complex).
  final dynamic value;

  /// Array index written.
  final int index;

  /// Write priority used.
  final int priority;

  /// Creates a WriteProperty notification response.
  const WriteNotificationResponse({
    required this.objectType,
    required this.instance,
    required this.propertyId,
    this.value,
    this.index = -1,
    this.priority = 16,
  });
}

/// Request to read a range of items from a list property (e.g. TrendLog).
class ReadRangeRequest extends WorkerRequest {
  /// Target device ID.
  final int deviceId;

  /// Object type (usually trendLog).
  final int objectType;

  /// Object instance number.
  final int instance;

  /// Property identifier (usually logBuffer).
  final int propertyId;

  /// Array index.
  final int arrayIndex;

  /// Request type: 1=Position, 2=Sequence, 4=Time, 8=All.
  final int requestType;

  /// Reference value (Index, Sequence Number, or DateTime string).
  final dynamic reference;

  /// Number of items to read (positive for forward, negative for backward).
  final int count;

  /// Optional tracking ID.
  final int? trackingId;

  /// Creates a ReadRange request.
  const ReadRangeRequest({
    required this.deviceId,
    required this.objectType,
    required this.instance,
    required this.propertyId,
    this.arrayIndex = -1,
    this.requestType = 1, // RR_BY_POSITION
    this.reference = 1, // Start index 1
    this.count = 0, // All? or specific count
    this.trackingId,
  });
}

/// Response containing a ReadRange acknowledgment.
class ReadRangeAckResponse extends WorkerResponse {
  /// Invoke ID.
  final int invokeId;

  /// Result flags (first item, last item, more items).
  final int resultFlags;

  /// Item count returned.
  final int itemCount;

  /// List of items (raw data or parsed).
  final dynamic data;

  /// Tracking ID associated with the request (if any).
  final int? trackingId;

  /// Creates a ReadRange acknowledgment.
  const ReadRangeAckResponse({
    required this.invokeId,
    required this.resultFlags,
    required this.itemCount,
    this.data,
    this.trackingId,
  });
}
