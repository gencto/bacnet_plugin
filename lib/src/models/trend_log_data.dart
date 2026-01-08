import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

part 'trend_log_data.g.dart';

/// Represents data tracked by a BACnet Trend Log object.
///
/// Trend logs collect and store historical values of properties
/// over time. This class holds the metadata and log entries.
///
/// Example:
/// ```dart
/// final logData = TrendLogData(
///   itemCount: 100,
///   totalRecords: 1000,
///   entries: [
///     TrendLogEntry(
///       timestamp: DateTime.now(),
///       value: 22.5,
///       status: 'OK',
///     ),
///   ],
/// );
/// ```
@immutable
@JsonSerializable()
class TrendLogData {
  /// Creates trend log data.
  ///
  /// [itemCount] is the number of entries currently in the log.
  /// [totalRecords] is total number of records that have been logged.
  /// [entries] is the list of log entries.
  const TrendLogData({
    required this.itemCount,
    required this.totalRecords,
    this.entries = const [],
  });

  /// The number of entries currently in the trend log.
  final int itemCount;

  /// The total number of records logged (may exceed current item count).
  final int totalRecords;

  /// List of trend log entries.
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

/// Represents a single entry in a trend log.
///
/// Each entry contains a timestamp, the logged value, and status information.
@immutable
@JsonSerializable()
class TrendLogEntry {
  /// Creates a trend log entry.
  ///
  /// [timestamp] is when the value was logged.
  /// [value] is the logged value (type depends on monitored property).
  /// [status] is the status flags at the time of logging.
  const TrendLogEntry({
    required this.timestamp,
    required this.value,
    required this.status,
  });

  /// The timestamp when this value was logged.
  final DateTime timestamp;

  /// The logged value.
  ///
  /// Type depends on the property being monitored
  /// (e.g., double for analog, bool for binary).
  final dynamic value;

  /// Status flags at the time of logging.
  ///
  /// Common values: 'OK', 'IN_ALARM', 'FAULT', etc.
  final String status;

  /// Creates a trend log entry from JSON.
  factory TrendLogEntry.fromJson(Map<String, dynamic> json) =>
      _$TrendLogEntryFromJson(json);

  /// Converts this entry to JSON.
  Map<String, dynamic> toJson() => _$TrendLogEntryToJson(this);

  /// Creates a copy with updated values.
  TrendLogEntry copyWith({DateTime? timestamp, dynamic value, String? status}) {
    return TrendLogEntry(
      timestamp: timestamp ?? this.timestamp,
      value: value ?? this.value,
      status: status ?? this.status,
    );
  }

  @override
  String toString() => 'TrendLogEntry($timestamp: $value [$status])';
}
