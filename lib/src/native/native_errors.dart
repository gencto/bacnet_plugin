import '../constants/error_codes.dart';
import '../core/exceptions.dart';
import 'bindings.g.dart';

/// Human readable text of a negative native result code (`BP_ERR_*`).
String nativeErrorMessage(int code) => switch (code) {
  BP_ERR_NOT_INITIALIZED => 'stack not initialized',
  BP_ERR_ALREADY_INITIALIZED => 'stack already initialized',
  BP_ERR_INVALID_ARGUMENT => 'invalid argument',
  BP_ERR_DATALINK => 'BACnet/IP datalink initialization failed',
  BP_ERR_NOT_BOUND => 'device address unknown',
  BP_ERR_NO_TRANSACTION => 'no free transaction',
  BP_ERR_APDU_TOO_LARGE => 'request exceeds the maximum APDU of the device',
  BP_ERR_SEND_FAILED => 'send failed',
  BP_ERR_COMMUNICATION_DISABLED => 'communication disabled (DCC)',
  BP_ERR_OBJECT => 'object operation failed',
  BP_ERR_NO_MEMORY => 'out of memory',
  BP_ERR_UNSUPPORTED => 'not supported for this object type',
  BP_ERR_SERVER_DISABLED => 'server not initialized',
  _ => 'native error $code',
};

/// Exception for a negative native result code.
///
/// Requests that do not fit into the APDU of the device are reported like
/// a local abort so that callers can split them (see
/// [BacnetAbortException.isSegmentationNotSupported]).
BacnetException nativeError(int code) => code == BP_ERR_APDU_TOO_LARGE
    ? BacnetAbortException(
        nativeErrorMessage(code),
        reason: BacnetAbortReason.apduTooLong,
        fromServer: false,
      )
    : BacnetException(nativeErrorMessage(code));

/// Throws [nativeError] when [code] is negative, returns it otherwise.
int checkNative(int code) {
  if (code < 0) throw nativeError(code);
  return code;
}
