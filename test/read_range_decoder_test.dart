import 'dart:ffi' as ffi;

import 'package:bacnet_plugin/src/native/worker/read_range_decoder.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReadRangeDecoder', () {
    test('Decodes simple ReadRange response with Unsigned items', () {
      // Mock Data:
      // Tag 3 (ResultFlags): Context(3), Len(1) -> 0x39
      //   BitString Len 1 (unused bits) -> 0x01
      //   Flags: 0x00 (None) -> 0x00
      // Tag 4 (ItemCount): Context(4), Len(1) -> 0x49
      //   Count: 2 -> 0x02
      // Tag 6 (ItemData): Opening (6) -> 0x6E
      //   App Tag Unsigned (2), Len 1 -> 0x21
      //   Value: 10 -> 0x0A
      //   App Tag Unsigned (2), Len 1 -> 0x21
      //   Value: 20 -> 0x14
      // Tag 6 (ItemData): Closing (7) -> 0x6F

      final mockData = [
        0x39, 0x01, 0x00, // ResultFlags
        0x49, 0x02, // ItemCount = 2
        0x6E, // Open ItemData
        0x21, 0x0A, // Unsigned 10
        0x21, 0x14, // Unsigned 20
        0x6F, // Close ItemData
      ];

      final ptr = calloc<ffi.Uint8>(mockData.length);
      for (int i = 0; i < mockData.length; i++) {
        ptr[i] = mockData[i];
      }

      try {
        final result = ReadRangeDecoder.decode(ptr, mockData.length);

        expect(result['count'], equals(2));
        expect(result['data'], isA<List<dynamic>>());
        expect(result['data'], hasLength(2));
        expect(result['data'][0], equals(10));
        expect(result['data'][1], equals(20));
      } finally {
        calloc.free(ptr);
      }
    });

    test('Decodes Mixed Types (Real, ObjectID)', () {
      // Tag 6 (ItemData): Opening -> 0x6E
      //   Real (4), Len 4 -> 0x44
      //   Value: 12.5 (0x41480000)
      //   ObjectID (12), Len 4 -> 0xC4
      //   Value: Type 8 (Device), Inst 100 -> (8<<22) | 100 -> 0x02000064
      // Tag 6 Closing -> 0x6F

      final mockData = [
        0x6E,
        0x44, 0x41, 0x48, 0x00, 0x00, // Real 12.5
        0xC4, 0x02, 0x00, 0x00, 0x64, // Device:100
        0x6F,
      ];

      final ptr = calloc<ffi.Uint8>(mockData.length);
      for (int i = 0; i < mockData.length; i++) {
        ptr[i] = mockData[i];
      }

      try {
        final result = ReadRangeDecoder.decode(ptr, mockData.length);
        expect(result['data'][0], closeTo(12.5, 0.001));
        expect(result['data'][1], equals({'type': 8, 'instance': 100}));
      } finally {
        calloc.free(ptr);
      }
    });
  });
}
