import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import '../constants/errors.dart';
import 'bacnet_value.dart';

part 'trend_log_data.g.dart';

/// Records read from a BACnet Trend Log object.
///
/// ```dart
/// final log = await client.getTrendLog(1234, 1, count: 50);
/// for (final entry in log.entries) {
///   print('${entry.timestamp}: ${entry.value?.asDouble}');
/// }
/// ```
@immutable
@JsonSerializable(explicitToJson: true)
class TrendLogData {
  /// Creates trend log data.
  ///
  /// [itemCount] is the number of returned entries, [totalRecords] the
  /// number of records logged so far.
  const TrendLogData({
    required this.itemCount,
    required this.totalRecords,
    this.entries = const [],
  });

  /// The number of entries returned.
  final int itemCount;

  /// The total number of records logged (may exceed [itemCount]).
  final int totalRecords;

  /// The returned records, oldest first.
  final List<TrendLogEntry> entries;

  /// Creates trend log data from JSON.
  factory TrendLogData.fromJson(Map<String, dynamic> json) =>
      _$TrendLogDataFromJson(json);

  /// Converts this trend log data to JSON.
  Map<String, dynamic> toJson() => _$TrendLogDataToJson(this);

  /// Creates a copy with updated values.
  TrendLogData copyWith({
    int? itemCount,
    int? totalRecords,
    List<TrendLogEntry>? entries,
  }) {
    return TrendLogData(
      itemCount: itemCount ?? this.itemCount,
      totalRecords: totalRecords ?? this.totalRecords,
      entries: entries ?? this.entries,
    );
  }

  @override
  String toString() =>
      'TrendLogData($itemCount items, $totalRecords total records)';
}

/// One record of a trend log (BACnetLogRecord).
@immutable
@JsonSerializable(explicitToJson: true)
class TrendLogEntry {
  /// Creates a trend log entry.
  const TrendLogEntry({
    required this.timestamp,
    required this.datum,
    this.statusFlags,
  });

  /// The time the record was logged.
  final DateTime timestamp;

  /// What was logged: a value, a change of the log's status, a failed read
  /// or a clock change.
  final TrendLogDatum datum;

  /// Status flags of the monitored object, if the record has them.
  final BacnetStatusFlags? statusFlags;

  /// The logged value, or null when the record is not a value.
  BacnetValue? get value => switch (datum) {
    TrendLogValue(:final value) => value,
    _ => null,
  };

  /// Creates a trend log entry from JSON.
  factory TrendLogEntry.fromJson(Map<String, dynamic> json) =>
      _$TrendLogEntryFromJson(json);

  /// Converts this entry to JSON.
  Map<String, dynamic> toJson() => _$TrendLogEntryToJson(this);

  /// Creates a copy with updated values.
  TrendLogEntry copyWith({
    DateTime? timestamp,
    TrendLogDatum? datum,
    BacnetStatusFlags? statusFlags,
  }) {
    return TrendLogEntry(
      timestamp: timestamp ?? this.timestamp,
      datum: datum ?? this.datum,
      statusFlags: statusFlags ?? this.statusFlags,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrendLogEntry &&
      other.timestamp == timestamp &&
      other.datum == datum &&
      other.statusFlags == statusFlags;

  @override
  int get hashCode => Object.hash(timestamp, datum, statusFlags);

  @override
  String toString() =>
      'TrendLogEntry($timestamp: $datum${statusFlags == null ? '' : ' [$statusFlags]'})';
}

/// The content of a trend log record (the log-datum choice of
/// BACnetLogRecord). The class is sealed:
///
/// ```dart
/// switch (entry.datum) {
///   case TrendLogValue(:final value):
///     print(value.asDouble);
///   case TrendLogStatus(:final logDisabled):
///     print(logDisabled ? 'logging stopped' : 'logging started');
///   case TrendLogFailure(:final error):
///     print('read failed: $error');
///   case TrendLogTimeChange(:final seconds):
///     print('clock changed by $seconds s');
/// }
/// ```
@immutable
sealed class TrendLogDatum {
  const TrendLogDatum();

  /// Creates a datum from the JSON produced by [toJson].
  ///
  /// Throws a [FormatException] for malformed JSON.
  factory TrendLogDatum.fromJson(Map<String, Object?> json) {
    switch (json) {
      case {'kind': 'value', 'value': final Map<String, Object?> value}:
        return TrendLogValue(BacnetValue.fromJson(value));
      case {'kind': 'status'}:
        return TrendLogStatus(
          logDisabled: json['logDisabled'] == true,
          bufferPurged: json['bufferPurged'] == true,
          logInterrupted: json['logInterrupted'] == true,
        );
      case {
        'kind': 'failure',
        'errorClass': final int errorClass,
        'errorCode': final int errorCode,
      }:
        return TrendLogFailure(
          BacnetError(BacnetErrorClass(errorClass), BacnetErrorCode(errorCode)),
        );
      case {'kind': 'timeChange', 'seconds': final num seconds}:
        return TrendLogTimeChange(seconds.toDouble());
    }
    throw FormatException('malformed trend log datum $json');
  }

  /// Converts the datum to JSON.
  Map<String, Object?> toJson();
}

/// A logged value.
final class TrendLogValue extends TrendLogDatum {
  /// Creates a value record.
  const TrendLogValue(this.value);

  /// The value of the monitored property.
  final BacnetValue value;

  @override
  Map<String, Object?> toJson() => {'kind': 'value', 'value': value.toJson()};

  @override
  bool operator ==(Object other) =>
      other is TrendLogValue && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$value';
}

/// A change of the log's own status (BACnetLogStatus).
final class TrendLogStatus extends TrendLogDatum {
  /// Creates a status record.
  const TrendLogStatus({
    this.logDisabled = false,
    this.bufferPurged = false,
    this.logInterrupted = false,
  });

  /// Logging is disabled.
  final bool logDisabled;

  /// The buffer was purged.
  final bool bufferPurged;

  /// Records were lost, e.g. while the device was restarting.
  final bool logInterrupted;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'status',
    'logDisabled': logDisabled,
    'bufferPurged': bufferPurged,
    'logInterrupted': logInterrupted,
  };

  @override
  bool operator ==(Object other) =>
      other is TrendLogStatus &&
      other.logDisabled == logDisabled &&
      other.bufferPurged == bufferPurged &&
      other.logInterrupted == logInterrupted;

  @override
  int get hashCode => Object.hash(logDisabled, bufferPurged, logInterrupted);

  @override
  String toString() =>
      'TrendLogStatus(disabled: $logDisabled, purged: $bufferPurged, '
      'interrupted: $logInterrupted)';
}

/// The log could not read the monitored property.
final class TrendLogFailure extends TrendLogDatum {
  /// Creates a failure record.
  const TrendLogFailure(this.error);

  /// The error returned by the monitored device.
  final BacnetError error;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'failure',
    'errorClass': error.errorClass as int,
    'errorCode': error.errorCode as int,
  };

  @override
  bool operator ==(Object other) =>
      other is TrendLogFailure && other.error == error;

  @override
  int get hashCode => error.hashCode;

  @override
  String toString() => '$error';
}

/// The device clock was changed.
final class TrendLogTimeChange extends TrendLogDatum {
  /// Creates a time change record.
  const TrendLogTimeChange(this.seconds);

  /// The clock change in seconds (0 when unknown).
  final double seconds;

  @override
  Map<String, Object?> toJson() => {'kind': 'timeChange', 'seconds': seconds};

  @override
  bool operator ==(Object other) =>
      other is TrendLogTimeChange && other.seconds == seconds;

  @override
  int get hashCode => seconds.hashCode;

  @override
  String toString() => 'TrendLogTimeChange($seconds s)';
}
