import 'package:meta/meta.dart';

import '../constants/property_ids.dart';
import 'alarms.dart' show BacnetRecipient;
import 'bacnet_value.dart' show BacnetObject;
import 'complex_values.dart' show BacnetTimeStamp;

/// The operation an audit record describes (BACnetAuditOperation, ASHRAE 135
/// clause 21). Create with `BacnetAuditOperation(value)` for proprietary
/// operations.
extension type const BacnetAuditOperation(int value) implements int {
  /// A property was read.
  static const read = BacnetAuditOperation(0);

  /// A property was written.
  static const write = BacnetAuditOperation(1);

  /// An object was created.
  static const create = BacnetAuditOperation(2);

  /// An object was deleted.
  static const delete = BacnetAuditOperation(3);

  /// A life safety operation was performed.
  static const lifeSafety = BacnetAuditOperation(4);

  /// An alarm was acknowledged.
  static const acknowledgeAlarm = BacnetAuditOperation(5);

  /// Device communication was disabled.
  static const deviceDisableComm = BacnetAuditOperation(6);

  /// Device communication was enabled.
  static const deviceEnableComm = BacnetAuditOperation(7);

  /// The device was reset.
  static const deviceReset = BacnetAuditOperation(8);

  /// The device was backed up.
  static const deviceBackup = BacnetAuditOperation(9);

  /// The device was restored.
  static const deviceRestore = BacnetAuditOperation(10);

  /// A subscription changed.
  static const subscription = BacnetAuditOperation(11);

  /// A notification was sent.
  static const notification = BacnetAuditOperation(12);

  /// Auditing itself failed.
  static const auditingFailure = BacnetAuditOperation(13);

  /// The network configuration changed.
  static const networkChanges = BacnetAuditOperation(14);

  /// A general operation not covered by the others.
  static const general = BacnetAuditOperation(15);

  static const _labels = <BacnetAuditOperation, String>{
    read: 'read',
    write: 'write',
    create: 'create',
    delete: 'delete',
    lifeSafety: 'life safety',
    acknowledgeAlarm: 'acknowledge alarm',
    deviceDisableComm: 'disable communication',
    deviceEnableComm: 'enable communication',
    deviceReset: 'device reset',
    deviceBackup: 'device backup',
    deviceRestore: 'device restore',
    subscription: 'subscription',
    notification: 'notification',
    auditingFailure: 'auditing failure',
    networkChanges: 'network changes',
    general: 'general',
  };

  /// A human-readable label.
  String get label => _labels[this] ?? 'operation $value';
}

/// How much an Audit Reporter audits (BACnetAuditLevel).
extension type const BacnetAuditLevel(int value) implements int {
  /// Nothing is audited.
  static const none = BacnetAuditLevel(0);

  /// All auditable operations are audited.
  static const auditAll = BacnetAuditLevel(1);

  /// Only configuration changes are audited.
  static const auditConfig = BacnetAuditLevel(2);

  /// The device's default audit behavior.
  static const defaultLevel = BacnetAuditLevel(3);
}

/// One BACnetAuditNotification: an operation on a target object, who initiated
/// it and when (ASHRAE 135-2016bi).
@immutable
final class BacnetAuditNotification {
  /// Creates an audit notification.
  const BacnetAuditNotification({
    required this.operation,
    required this.sourceDevice,
    required this.targetDevice,
    this.sourceTimestamp,
    this.targetObject,
    this.targetProperty,
  });

  /// The operation that was performed.
  final BacnetAuditOperation operation;

  /// The initiator of the operation.
  final BacnetRecipient sourceDevice;

  /// The device the operation targeted.
  final BacnetRecipient targetDevice;

  /// When the source observed the operation.
  final BacnetTimeStamp? sourceTimestamp;

  /// The object the operation targeted.
  final BacnetObject? targetObject;

  /// The property the operation targeted.
  final BacnetPropertyId? targetProperty;

  @override
  String toString() =>
      'BacnetAuditNotification(${operation.label}'
      '${targetObject != null ? ' $targetObject' : ''}'
      '${targetProperty != null ? '.${targetProperty!.label}' : ''})';
}

/// One record of an Audit Log: a timestamped operation, a log status change or
/// a time change.
@immutable
final class BacnetAuditLogRecord {
  /// Creates a record.
  const BacnetAuditLogRecord({
    required this.timestamp,
    this.notification,
    this.logStatus,
    this.timeChange,
  });

  /// When the record was stored.
  final DateTime timestamp;

  /// The audited operation, for a notification record.
  final BacnetAuditNotification? notification;

  /// The log status bits, for a log-status record.
  final int? logStatus;

  /// The clock change in seconds, for a time-change record.
  final double? timeChange;

  @override
  String toString() =>
      'BacnetAuditLogRecord($timestamp, '
      '${notification ?? (logStatus != null ? 'status $logStatus' : 'time change $timeChange')})';
}

/// The result of an AuditLogQuery.
@immutable
final class BacnetAuditLogQueryResult {
  /// Creates the result.
  const BacnetAuditLogQueryResult({
    required this.auditLog,
    required this.records,
    required this.noMoreItems,
  });

  /// The queried Audit Log object.
  final BacnetObject auditLog;

  /// The matching records.
  final List<BacnetAuditLogRecord> records;

  /// True when the log has no more records beyond those returned.
  final bool noMoreItems;
}
