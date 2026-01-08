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
      'entries': instance.entries,
    };

TrendLogEntry _$TrendLogEntryFromJson(Map<String, dynamic> json) =>
    TrendLogEntry(
      timestamp: DateTime.parse(json['timestamp'] as String),
      value: json['value'],
      status: json['status'] as String,
    );

Map<String, dynamic> _$TrendLogEntryToJson(TrendLogEntry instance) =>
    <String, dynamic>{
      'timestamp': instance.timestamp.toIso8601String(),
      'value': instance.value,
      'status': instance.status,
    };
