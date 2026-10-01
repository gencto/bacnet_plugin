import '../constants/errors.dart';
import '../models/bacnet_value.dart';
import '../models/trend_log_data.dart';
import 'reader.dart';
import 'value_encoding.dart';

/// Converts ReadRange items of a Trend Log `log-buffer` into entries.
///
/// Every BACnetLogRecord is three consecutive items: the timestamp
/// (constructed `[0]`), the log datum (constructed `[1]`) and optional status
/// flags (context `[2]`).
List<TrendLogEntry> decodeLogRecords(List<BacnetValue> items) {
  final entries = <TrendLogEntry>[];
  DateTime? timestamp;
  TrendLogDatum? datum;
  BacnetStatusFlags? statusFlags;

  void flush() {
    if (timestamp case final timestamp?) {
      if (datum case final datum?) {
        entries.add(
          TrendLogEntry(
            timestamp: timestamp,
            datum: datum,
            statusFlags: statusFlags,
          ),
        );
      }
    }
    timestamp = null;
    datum = null;
    statusFlags = null;
  }

  for (final item in items) {
    switch (item) {
      case BacnetConstructedValue(tag: 0, :final values):
        flush();
        final date = values.whereType<BacnetDate>().firstOrNull;
        final time = values.whereType<BacnetTime>().firstOrNull;
        final day = date?.toDateTime();
        timestamp = day == null
            ? DateTime.fromMillisecondsSinceEpoch(0)
            : day.add(time?.toDuration() ?? Duration.zero);
      case BacnetConstructedValue(tag: 1, :final values) when values.isNotEmpty:
        datum = _decodeLogDatum(values.first);
      case BacnetContextValue(tag: 2, :final data):
        statusFlags = BacnetStatusFlags.fromBitString(
          BacnetReader.bitStringFrom(data),
        );
      default:
        break;
    }
  }
  flush();
  return entries;
}

TrendLogDatum _decodeLogDatum(BacnetValue choice) {
  switch (choice) {
    case BacnetContextValue(:final tag, data: final bytes):
      return switch (tag) {
        0 => _logStatus(BacnetReader.bitStringFrom(bytes)),
        1 => TrendLogValue(BacnetBoolean(bytes.isNotEmpty && bytes[0] != 0)),
        2 => TrendLogValue(BacnetReal(BacnetReader.realFrom(bytes))),
        3 => TrendLogValue(BacnetEnumerated(BacnetReader.unsignedFrom(bytes))),
        4 => TrendLogValue(BacnetUnsigned(BacnetReader.unsignedFrom(bytes))),
        5 => TrendLogValue(BacnetSigned(BacnetReader.signedFrom(bytes))),
        6 => TrendLogValue(BacnetReader.bitStringFrom(bytes)),
        7 => const TrendLogValue(BacnetNull()),
        9 => TrendLogTimeChange(BacnetReader.realFrom(bytes)),
        _ => TrendLogValue(choice),
      };
    case BacnetConstructedValue(tag: 8, :final values) when values.length >= 2:
      return TrendLogFailure(
        BacnetError(
          BacnetErrorClass(values[0].asInt ?? -1),
          BacnetErrorCode(values[1].asInt ?? -1),
        ),
      );
    case BacnetConstructedValue(tag: 10, :final values):
      return TrendLogValue(collapseValues(values));
    default:
      return TrendLogValue(choice);
  }
}

TrendLogStatus _logStatus(BacnetBitString bits) => TrendLogStatus(
  logDisabled: bits[0],
  bufferPurged: bits[1],
  logInterrupted: bits[2],
);
