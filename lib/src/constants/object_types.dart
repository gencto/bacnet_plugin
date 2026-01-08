/// BACnet Object Type constants.
///
/// Defines standard BACnet object types as per ASHRAE Standard 135.
class BacnetObjectType {
  const BacnetObjectType._();

  /// Analog Input (AI) object type.
  static const int analogInput = 0;

  /// Analog Output (AO) object type.
  static const int analogOutput = 1;

  /// Analog Value (AV) object type.
  static const int analogValue = 2;

  /// Binary Input (BI) object type.
  static const int binaryInput = 3;

  /// Binary Output (BO) object type.
  static const int binaryOutput = 4;

  /// Binary Value (BV) object type.
  static const int binaryValue = 5;

  /// Calendar object type.
  static const int calendar = 6;

  /// Command object type.
  static const int command = 7;

  /// Device object type.
  static const int device = 8;

  /// Event Enrollment object type.
  static const int eventEnrollment = 9;

  /// File object type.
  static const int file = 10;

  /// Group object type.
  static const int group = 11;

  /// Loop object type.
  static const int loop = 12;

  /// Multi-state Input (MSI) object type.
  static const int multiStateInput = 13;

  /// Multi-state Output (MSO) object type.
  static const int multiStateOutput = 14;

  /// Multi-state Value (MSV) object type.
  static const int multiStateValue = 19;

  /// Notification Class object type.
  static const int notificationClass = 15;

  /// Program object type.
  static const int program = 16;

  /// Schedule object type.
  static const int schedule = 17;

  /// Averaging object type.
  static const int averaging = 18;

  /// Trend Log object type.
  static const int trendLog = 20;

  /// Life Safety Point object type.
  static const int lifeSafetyPoint = 21;

  /// Life Safety Zone object type.
  static const int lifeSafetyZone = 22;

  /// Accumulator object type.
  static const int accumulator = 23;

  /// Pulse Converter object type.
  static const int pulseConverter = 24;

  /// Returns a human-readable name for the given object type.
  static String getName(int objectType) {
    switch (objectType) {
      case analogInput:
        return 'Analog Input';
      case analogOutput:
        return 'Analog Output';
      case analogValue:
        return 'Analog Value';
      case binaryInput:
        return 'Binary Input';
      case binaryOutput:
        return 'Binary Output';
      case binaryValue:
        return 'Binary Value';
      case calendar:
        return 'Calendar';
      case command:
        return 'Command';
      case device:
        return 'Device';
      case eventEnrollment:
        return 'Event Enrollment';
      case file:
        return 'File';
      case group:
        return 'Group';
      case loop:
        return 'Loop';
      case multiStateInput:
        return 'Multi-state Input';
      case multiStateOutput:
        return 'Multi-state Output';
      case multiStateValue:
        return 'Multi-state Value';
      case notificationClass:
        return 'Notification Class';
      case program:
        return 'Program';
      case schedule:
        return 'Schedule';
      case averaging:
        return 'Averaging';
      case trendLog:
        return 'Trend Log';
      case lifeSafetyPoint:
        return 'Life Safety Point';
      case lifeSafetyZone:
        return 'Life Safety Zone';
      case accumulator:
        return 'Accumulator';
      case pulseConverter:
        return 'Pulse Converter';
      default:
        return 'Unknown ($objectType)';
    }
  }
}
