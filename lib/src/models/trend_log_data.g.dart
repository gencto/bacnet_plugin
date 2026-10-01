// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'trend_log_data.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

TrendLogData _$TrendLogDataFromJson(Map<String, dynamic> json) => TrendLogData(
  itemCount: (json['itemCount'] as num).toInt(),
  totalRecords: (json['totalRecords'] as num).toInt(),
  entries:
      (json['entries'] as List<dynamic>?)
          ?.map((e) => TrendLogEntry.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
);

Map<String, dynamic> _$TrendLogDataToJson(TrendLogData instance) =>
    <String, dynamic>{
      'itemCount': instance.itemCount,
      'totalRecords': instance.totalRecords,
      'entries': instance.entries.map((e) => e.toJson()).toList(),
    };

TrendLogEntry _$TrendLogEntryFromJson(Map<String, dynamic> json) =>
    TrendLogEntry(
      timestamp: DateTime.parse(json['timestamp'] as String),
      datum: TrendLogDatum.fromJson(json['datum'] as Map<String, dynamic>),
      statusFlags: json['statusFlags'] == null
          ? null
          : BacnetStatusFlags.fromJson(
              json['statusFlags'] as Map<String, dynamic>,
            ),
    );

Map<String, dynamic> _$TrendLogEntryToJson(TrendLogEntry instance) =>
    <String, dynamic>{
      'timestamp': instance.timestamp.toIso8601String(),
      'datum': instance.datum.toJson(),
      'statusFlags': instance.statusFlags?.toJson(),
    };
