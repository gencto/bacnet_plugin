/// BACnet Property Identifier constants.
///
/// Defines standard BACnet property identifiers as per ASHRAE Standard 135.
class BacnetPropertyId {
  const BacnetPropertyId._();

  /// Acked Transitions property (0).
  static const int ackedTransitions = 0;

  /// Ack Required property (1).
  static const int ackRequired = 1;

  /// Action property (2).
  static const int action = 2;

  /// Action Text property (3).
  static const int actionText = 3;

  /// Active Text property (4).
  static const int activeText = 4;

  /// Active VT Sessions property (5).
  static const int activeVtSessions = 5;

  /// Alarm Value property (6).
  static const int alarmValue = 6;

  /// Alarm Values property (7).
  static const int alarmValues = 7;

  /// All property (8).
  static const int all = 8;

  /// APDU Segment Timeout property (10).
  static const int apduSegmentTimeout = 10;

  /// APDU Timeout property (11).
  static const int apduTimeout = 11;

  /// Application Software Version property (12).
  static const int applicationSoftwareVersion = 12;

  /// Archive property (13).
  static const int archive = 13;

  /// Bias property (14).
  static const int bias = 14;

  /// Change of State Count property (15).
  static const int changeOfStateCount = 15;

  /// Change of State Time property (16).
  static const int changeOfStateTime = 16;

  /// Notification Class property (17).
  static const int notificationClass = 17;

  /// Description property (28).
  static const int description = 28;

  /// Device Address Binding property (30).
  static const int deviceAddressBinding = 30;

  /// Device Type property (31).
  static const int deviceType = 31;

  /// Effective Period property (32).
  static const int effectivePeriod = 32;

  /// Elapsed Active Time property (33).
  static const int elapsedActiveTime = 33;

  /// Error Limit property (34).
  static const int errorLimit = 34;

  /// Event Enable property (35).
  static const int eventEnable = 35;

  /// Event State property (36).
  static const int eventState = 36;

  /// Event Type property (37).
  static const int eventType = 37;

  /// Exception Schedule property (38).
  static const int exceptionSchedule = 38;

  /// Fault Values property (39).
  static const int faultValues = 39;

  /// Feedback Value property (40).
  static const int feedbackValue = 40;

  /// File Access Method property (41).
  static const int fileAccessMethod = 41;

  /// File Size property (42).
  static const int fileSize = 42;

  /// File Type property (43).
  static const int fileType = 43;

  /// Firmware Revision property (44).
  static const int firmwareRevision = 44;

  /// High Limit property (45).
  static const int highLimit = 45;

  /// Inactive Text property (46).
  static const int inactiveText = 46;

  /// In Process property (47).
  static const int inProcess = 47;

  /// Instance Of property (48).
  static const int instanceOf = 48;

  /// Limit Enable property (52).
  static const int limitEnable = 52;

  /// List of Group Members property (53).
  static const int listOfGroupMembers = 53;

  /// List of Object Property References property (54).
  static const int listOfObjectPropertyReferences = 54;

  /// Local Date property (56).
  static const int localDate = 56;

  /// Local Time property (57).
  static const int localTime = 57;

  /// Location property (58).
  static const int location = 58;

  /// Low Limit property (59).
  static const int lowLimit = 59;

  /// Manipulated Variable Reference property (60).
  static const int manipulatedVariableReference = 60;

  /// Maximum Output property (61).
  static const int maximumOutput = 61;

  /// Max APDU Length Accepted property (62).
  static const int maxApduLengthAccepted = 62;

  /// Max Info Frames property (63).
  static const int maxInfoFrames = 63;

  /// Max Master property (64).
  static const int maxMaster = 64;

  /// Max Pres Value property (65).
  static const int maxPresValue = 65;

  /// Minimum Off Time property (66).
  static const int minimumOffTime = 66;

  /// Minimum On Time property (67).
  static const int minimumOnTime = 67;

  /// Minimum Output property (68).
  static const int minimumOutput = 68;

  /// Min Pres Value property (69).
  static const int minPresValue = 69;

  /// Model Name property (70).
  static const int modelName = 70;

  /// Modification Date property (71).
  static const int modificationDate = 71;

  /// Notify Type property (72).
  static const int notifyType = 72;

  /// Number of APDU Retries property (73).
  static const int numberOfApduRetries = 73;

  /// Number of States property (74).
  static const int numberOfStates = 74;

  /// Object Identifier property (75).
  static const int objectIdentifier = 75;

  /// Object List property (76).
  static const int objectList = 76;

  /// Object Name property (77).
  static const int objectName = 77;

  /// Object Property Reference property (78).
  static const int objectPropertyReference = 78;

  /// Object Type property (79).
  static const int objectType = 79;

  /// Optional property (80).
  static const int optional = 80;

  /// Out of Service property (81).
  static const int outOfService = 81;

  /// Output Units property (82).
  static const int outputUnits = 82;

  /// Event Parameters property (83).
  static const int eventParameters = 83;

  /// Polarity property (84).
  static const int polarity = 84;

  /// Protocol Revision property (139).
  static const int protocolRevision = 139;

  /// Present Value property (85).
  static const int presentValue = 85;

  /// Priority property (86).
  static const int priority = 86;

  /// Priority Array property (87).
  static const int priorityArray = 87;

  /// Priority For Writing property (88).
  static const int priorityForWriting = 88;

  /// Process Identifier property (89).
  static const int processIdentifier = 89;

  /// Program Change property (90).
  static const int programChange = 90;

  /// Program Location property (91).
  static const int programLocation = 91;

  /// Program State property (92).
  static const int programState = 92;

  /// Proportional Constant property (93).
  static const int proportionalConstant = 93;

  /// Proportional Constant Units property (94).
  static const int proportionalConstantUnits = 94;

  /// Protocol Object Types Supported property (96).
  static const int protocolObjectTypesSupported = 96;

  /// Protocol Services Supported property (97).
  static const int protocolServicesSupported = 97;

  /// Protocol Version property (98).
  static const int protocolVersion = 98;

  /// Read Only property (99).
  static const int readOnly = 99;

  /// Reason for Halt property (100).
  static const int reasonForHalt = 100;

  /// Recipient List property (102).
  static const int recipientList = 102;

  /// Reliability property (103).
  static const int reliability = 103;

  /// Relinquish Default property (104).
  static const int relinquishDefault = 104;

  /// Required property (105).
  static const int required = 105;

  /// Resolution property (106).
  static const int resolution = 106;

  /// Segmentation Supported property (107).
  static const int segmentationSupported = 107;

  /// Setpoint property (108).
  static const int setpoint = 108;

  /// Setpoint Reference property (109).
  static const int setpointReference = 109;

  /// State Text property (110).
  static const int stateText = 110;

  /// Status Flags property (111).
  static const int statusFlags = 111;

  /// System Status property (112).
  static const int systemStatus = 112;

  /// Time Delay property (113).
  static const int timeDelay = 113;

  /// Time of Active Time Reset property (114).
  static const int timeOfActiveTimeReset = 114;

  /// Time of State Count Reset property (115).
  static const int timeOfStateCountReset = 115;

  /// Time Synchronization Recipients property (116).
  static const int timeSynchronizationRecipients = 116;

  /// Units property (117).
  static const int units = 117;

  /// Update Interval property (118).
  static const int updateInterval = 118;

  /// UTC Offset property (119).
  static const int utcOffset = 119;

  /// Vendor Identifier property (120).
  static const int vendorIdentifier = 120;

  /// Vendor Name property (121).
  static const int vendorName = 121;

  /// VT Classes Supported property (122).
  static const int vtClassesSupported = 122;

  /// Weekly Schedule property (123).
  static const int weeklySchedule = 123;

  /// Returns a human-readable name for the given property identifier.
  static String getName(int propertyId) {
    switch (propertyId) {
      case ackedTransitions:
        return 'Acked Transitions';
      case ackRequired:
        return 'Ack Required';
      case action:
        return 'Action';
      case actionText:
        return 'Action Text';
      case activeText:
        return 'Active Text';
      case description:
        return 'Description';
      case objectList:
        return 'Object List';
      case objectName:
        return 'Object Name';
      case objectType:
        return 'Object Type';
      case outOfService:
        return 'Out of Service';
      case presentValue:
        return 'Present Value';
      case priority:
        return 'Priority';
      case priorityArray:
        return 'Priority Array';
      case reliability:
        return 'Reliability';
      case relinquishDefault:
        return 'Relinquish Default';
      case statusFlags:
        return 'Status Flags';
      case units:
        return 'Units';
      case vendorName:
        return 'Vendor Name';
      case modelName:
        return 'Model Name';
      case applicationSoftwareVersion:
        return 'Application Software Version';
      case firmwareRevision:
        return 'Firmware Revision';
      case deviceType:
        return 'Device Type';
      case protocolVersion:
        return 'Protocol Version';
      case protocolServicesSupported:
        return 'Protocol Services Supported';
      case protocolObjectTypesSupported:
        return 'Protocol Object Types Supported';
      case systemStatus:
        return 'System Status';
      default:
        return 'Property $propertyId';
    }
  }
}
