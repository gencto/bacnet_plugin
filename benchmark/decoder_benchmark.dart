// ignore_for_file: avoid_print

import 'dart:ffi' as ffi;

import 'package:bacnet_plugin/src/native/worker/read_range_decoder.dart';
// Import internal decoders (requires accessible imports or path relativity if running from root)
// Since this is outside lib, we import via package
import 'package:bacnet_plugin/src/native/worker/rpm_decoder.dart';
import 'package:ffi/ffi.dart';

void main() {
  print('Running BACnet Decoder Benchmarks...');

  benchmarkRPMDecoder();
  benchmarkReadRangeDecoder();
}

void benchmarkRPMDecoder() {
  // Construct a complex RPM packet
  // Object ID (Tag 0)
  // Opening Tag 1
  //   Prop ID (Tag 2)
  //   Value (Tag 4 Opening)
  //     App Tag (Real)
  //   Value (Tag 4 Closing)
  // Closing Tag 1

  final mockData = <int>[
    0x0C, 0x02, 0x00, 0x00, 0x64, // Object Identifier: AnalogValue, 100 (Tag 0)
    0x1E, // Opening Tag 1
    0x29, 0x55, // Prop ID: 85 (Present Value) (Tag 2)
    0x4E, // Opening Tag 4 (Value)
    0x44, 0x42, 0xF6, 0xE6, 0x66, // Real: 123.45 (Tag 4 App)
    0x4F, // Closing Tag 4

    0x29, 0x4D, // Prop ID: 77 (Name) (Tag 2)
    0x4E, // Opening Tag 4
    // String "MyName" (Len 7: 1 encoding + 6 chars)
    // Tag 7 (0x70), LVT 5 (Extended) -> 0x75
    // Length: 7 -> 0x07
    // Encoding: 0 -> 0x00
    0x75, 0x07, 0x00, 0x4D, 0x79, 0x4E, 0x61, 0x6D, 0x65,
    0x4F, // Closing Tag 4
    0x1F, // Closing Tag 1
  ];

  final ptr = calloc<ffi.Uint8>(mockData.length);
  for (int i = 0; i < mockData.length; i++) {
    ptr[i] = mockData[i];
  }

  try {
    final stopwatch = Stopwatch()..start();
    const iterations = 10000;

    for (int i = 0; i < iterations; i++) {
      final res = RPMDecoder.decode(ptr, mockData.length);
      if (res.isEmpty) throw Exception('Decode failed');
    }

    stopwatch.stop();
    print(
      'RPMDecoder: ${stopwatch.elapsedMilliseconds}ms for $iterations iterations',
    );
    print(
      '  Avg: ${(stopwatch.elapsedMicroseconds / iterations).toStringAsFixed(2)} us/op',
    );
  } finally {
    calloc.free(ptr);
  }
}

void benchmarkReadRangeDecoder() {
  // Construct ReadRange response (TrendLog style)
  // ResultFlags (Tag 3)
  // ItemCount (Tag 4)
  // ItemData (Tag 6 Open)
  //   List of 10 Reals
  // ItemData (Tag 6 Close)

  final mockData = <int>[
    0x39, 0x01, 0x00, // ResultFlags (0)
    0x49, 0x0A, // ItemCount (10)
    0x6E, // Open ItemData (Tag 6)
  ];

  // Add 10 Reals
  for (int i = 0; i < 10; i++) {
    // Real (Tag 4), 1.0 * i
    mockData.addAll([0x44, 0x3F, 0x80, 0x00, 0x00]); // 1.0 approx
  }

  mockData.add(0x6F); // Close ItemData

  final ptr = calloc<ffi.Uint8>(mockData.length);
  for (int i = 0; i < mockData.length; i++) {
    ptr[i] = mockData[i];
  }

  try {
    final stopwatch = Stopwatch()..start();
    const iterations = 10000;

    for (int i = 0; i < iterations; i++) {
      final res = ReadRangeDecoder.decode(ptr, mockData.length);
      if (res['count'] != 10) throw Exception('Decode failed');
    }

    stopwatch.stop();
    print(
      'ReadRangeDecoder: ${stopwatch.elapsedMilliseconds}ms for $iterations iterations',
    );
    print(
      '  Avg: ${(stopwatch.elapsedMicroseconds / iterations).toStringAsFixed(2)} us/op',
    );
  } finally {
    calloc.free(ptr);
  }
}
