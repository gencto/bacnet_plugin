import '../core/types.dart';
import '../models/trend_log_data.dart';
import 'reader.dart';
import 'value_encoding.dart';
import 'values.dart';

/// Converts ReadRange items of a Trend Log `log-buffer` into entries.
///
/// Every BACnetLogRecord is three consecutive items: the timestamp
/// (constructed [0]), the log datum (constructed [1]) and optional status
/// flags (context [2]).
List<TrendLogEntry> decodeLogRecords(List<Object?> items) {
  final entries = <TrendLogEntry>[];
  DateTime? timestamp;
  Object? datum;
  var hasDatum = false;
  String status = 'OK';

  void flush() {
    if (timestamp != null && hasDatum) {
      entries.add(
        TrendLogEntry(timestamp: timestamp!, value: datum, status: status),
      );
    }
    timestamp = null;
    datum = null;
    hasDatum = false;
    status = 'OK';
  }

  for (final item in items) {
    if (item is BacnetConstructedValue && item.tag == 0) {
      flush();
      final date = item.values.whereType<BacnetDate>().firstOrNull;
      final time = item.values.whereType<BacnetTime>().firstOrNull;
      final day = date?.toDateTime();
      timestamp = day == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : day.add(time?.toDuration() ?? Duration.zero);
    } else if (item is BacnetConstructedValue && item.tag == 1) {
      hasDatum = true;
      datum = _decodeLogDatum(item.values.isEmpty ? null : item.values.first);
    } else if (item is BacnetContextValue && item.tag == 2) {
      status = BacnetStatusFlags.fromBitString(
        BacnetReader.bitStringFrom(item.data),
      ).toString();
    }
  }
  flush();
  return entries;
}

Object? _decodeLogDatum(Object? choice) {
  if (choice is BacnetContextValue) {
    final bytes = choice.data;
    switch (choice.tag) {
      case 0: // log-status
        return BacnetReader.bitStringFrom(bytes);
      case 1: // boolean
        return bytes.isNotEmpty && bytes[0] != 0;
      case 2: // real
      case 9: // time-change
        return BacnetReader.realFrom(bytes);
      case 3: // enumerated
      case 4: // unsigned
        return BacnetReader.unsignedFrom(bytes);
      case 5: // signed
        return BacnetReader.signedFrom(bytes);
      case 6: // bit string
        return BacnetReader.bitStringFrom(bytes);
      case 7: // null
        return null;
    }
    return choice;
  }
  if (choice is BacnetConstructedValue) {
    if (choice.tag == 8 && choice.values.length >= 2) {
      // failure: BACnetError
      final errorClass = choice.values[0];
      final errorCode = choice.values[1];
      return BacnetError(
        errorClass is int ? errorClass : -1,
        errorCode is int ? errorCode : -1,
      );
    }
    // any-value
    return collapseValues(choice.values);
  }
  return choice;
}
