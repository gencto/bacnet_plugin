/// BACnet Error Class constants.
///
/// Defines standard BACnet error classes as per ASHRAE Standard 135.
class BacnetErrorClass {
  const BacnetErrorClass._();

  /// Device error class.
  static const int device = 0;

  /// Object error class.
  static const int object = 1;

  /// Property error class.
  static const int property = 2;

  /// Resources error class.
  static const int resources = 3;

  /// Security error class.
  static const int security = 4;

  /// Services error class.
  static const int services = 5;

  /// VT (Virtual Terminal) error class.
  static const int vt = 6;

  /// Communication error class.
  static const int communication = 7;

  /// Returns a human-readable name for the given error class.
  static String getName(int errorClass) {
    switch (errorClass) {
      case device:
        return 'Device';
      case object:
        return 'Object';
      case property:
        return 'Property';
      case resources:
        return 'Resources';
      case security:
        return 'Security';
      case services:
        return 'Services';
      case vt:
        return 'VT';
      case communication:
        return 'Communication';
      default:
        return 'Unknown Class ($errorClass)';
    }
  }
}

/// BACnet Error Code constants.
///
/// Defines standard BACnet error codes as per ASHRAE Standard 135.
class BacnetErrorCode {
  const BacnetErrorCode._();

  /// Other error code.
  static const int other = 0;

  /// Authentication failed error code.
  static const int authenticationFailed = 1;

  /// Configuration in progress error code.
  static const int configurationInProgress = 2;

  /// Device busy error code.
  static const int deviceBusy = 3;

  /// Dynamic creation not supported error code.
  static const int dynamicCreationNotSupported = 4;

  /// File access denied error code.
  static const int fileAccessDenied = 5;

  /// Inconsistent parameters error code.
  static const int inconsistentParameters = 7;

  /// Inconsistent selection criterion error code.
  static const int inconsistentSelectionCriterion = 8;

  /// Invalid data type error code.
  static const int invalidDataType = 9;

  /// Invalid file access method error code.
  static const int invalidFileAccessMethod = 10;

  /// Invalid file start position error code.
  static const int invalidFileStartPosition = 11;

  /// Invalid operator name error code.
  static const int invalidOperatorName = 12;

  /// Invalid parameter data type error code.
  static const int invalidParameterDataType = 13;

  /// Invalid time stamp error code.
  static const int invalidTimeStamp = 14;

  /// Key generation error code.
  static const int keyGeneration = 15;

  /// Missing required parameter error code.
  static const int missingRequiredParameter = 16;

  /// No objects of specified type error code.
  static const int noObjectsOfSpecifiedType = 17;

  /// No space for object error code.
  static const int noSpaceForObject = 18;

  /// No space to add list element error code.
  static const int noSpaceToAddListElement = 19;

  /// No space to write property error code.
  static const int noSpaceToWriteProperty = 20;

  /// No VT sessions available error code.
  static const int noVtSessionsAvailable = 21;

  /// Property is not a list error code.
  static const int propertyIsNotAList = 22;

  /// Object deletion not permitted error code.
  static const int objectDeletionNotPermitted = 23;

  /// Object identifier already exists error code.
  static const int objectIdentifierAlreadyExists = 24;

  /// Operational problem error code.
  static const int operationalProblem = 25;

  /// Password failure error code.
  static const int passwordFailure = 26;

  /// Read access denied error code.
  static const int readAccessDenied = 27;

  /// Security not supported error code.
  static const int securityNotSupported = 28;

  /// Service request denied error code.
  static const int serviceRequestDenied = 29;

  /// Timeout error code.
  static const int timeout = 30;

  /// Unknown object error code.
  static const int unknownObject = 31;

  /// Unknown property error code.
  static const int unknownProperty = 32;

  /// Unknown VT class error code.
  static const int unknownVtClass = 34;

  /// Unknown VT session error code.
  static const int unknownVtSession = 35;

  /// Unsupported object type error code.
  static const int unsupportedObjectType = 36;

  /// Value out of range error code.
  static const int valueOutOfRange = 37;

  /// VT session already closed error code.
  static const int vtSessionAlreadyClosed = 38;

  /// VT session termination failure error code.
  static const int vtSessionTerminationFailure = 39;

  /// Write access denied error code.
  static const int writeAccessDenied = 40;

  /// Character set not supported error code.
  static const int characterSetNotSupported = 41;

  /// Invalid array index error code.
  static const int invalidArrayIndex = 42;

  /// COV subscription failed error code.
  static const int covSubscriptionFailed = 43;

  /// Not COV property error code.
  static const int notCovProperty = 44;

  /// Optional functionality not supported error code.
  static const int optionalFunctionalityNotSupported = 45;

  /// Invalid configuration data error code.
  static const int invalidConfigurationData = 46;

  /// Datatype not supported error code.
  static const int datatypeNotSupported = 47;

  /// Duplicate name error code.
  static const int duplicateName = 48;

  /// Duplicate object ID error code.
  static const int duplicateObjectId = 49;

  /// Property is not an array error code.
  static const int propertyIsNotAnArray = 50;

  /// Returns a human-readable name for the given error code.
  static String getName(int errorCode) {
    switch (errorCode) {
      case other:
        return 'Other';
      case authenticationFailed:
        return 'Authentication Failed';
      case deviceBusy:
        return 'Device Busy';
      case inconsistentParameters:
        return 'Inconsistent Parameters';
      case invalidDataType:
        return 'Invalid Data Type';
      case invalidParameterDataType:
        return 'Invalid Parameter Data Type';
      case missingRequiredParameter:
        return 'Missing Required Parameter';
      case noObjectsOfSpecifiedType:
        return 'No Objects of Specified Type';
      case readAccessDenied:
        return 'Read Access Denied';
      case timeout:
        return 'Timeout';
      case unknownObject:
        return 'Unknown Object';
      case unknownProperty:
        return 'Unknown Property';
      case unsupportedObjectType:
        return 'Unsupported Object Type';
      case valueOutOfRange:
        return 'Value Out of Range';
      case writeAccessDenied:
        return 'Write Access Denied';
      case invalidArrayIndex:
        return 'Invalid Array Index';
      case covSubscriptionFailed:
        return 'COV Subscription Failed';
      case notCovProperty:
        return 'Not COV Property';
      case optionalFunctionalityNotSupported:
        return 'Optional Functionality Not Supported';
      case datatypeNotSupported:
        return 'Datatype Not Supported';
      case duplicateName:
        return 'Duplicate Name';
      case duplicateObjectId:
        return 'Duplicate Object ID';
      case propertyIsNotAnArray:
        return 'Property Is Not An Array';
      default:
        return 'Error Code $errorCode';
    }
  }
}
