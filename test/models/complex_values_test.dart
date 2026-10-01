import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

import '../support/codec_helpers.dart';

const _noon = BacnetTime(hour: 12, minute: 0, second: 0, hundredths: 0);
const _evening = BacnetTime(hour: 18, minute: 30, second: 0, hundredths: 0);
const _christmas = BacnetDate(year: 2026, month: 12, day: 25, weekday: 5);
const _ai1 = BacnetObject(type: BacnetObjectType.analogInput, instance: 1);
const _device = BacnetObject(type: BacnetObjectType.device, instance: 260001);

/// Encodes [value] like a property value and decodes it like a read.
BacnetValue _wire(BacnetValue value) => roundTrip(value);

Matcher _malformed() => throwsA(isA<BacnetDecodeException>());

void main() {
  test('BacnetDateTime', () {
    final value = BacnetDateTime.fromDateTime(DateTime(2026, 10, 1, 8, 15));
    expect(BacnetDateTime.fromValue(_wire(value.toValue())), value);
    expect(value.toDateTime(), DateTime(2026, 10, 1, 8, 15));
    expect(
      () => BacnetDateTime.fromValue(const BacnetList([_noon, _christmas])),
      _malformed(),
    );
  });

  test('BacnetTimeStamp variants', () {
    final stamps = [
      const BacnetTimeStampTime(_noon),
      const BacnetTimeStampSequence(4711),
      const BacnetTimeStampDateTime(BacnetDateTime(_christmas, _evening)),
    ];
    final value = BacnetList([for (final stamp in stamps) stamp.toValue()]);
    expect(BacnetTimeStamp.listFromValue(_wire(value)), stamps);
    // context tag 0 with a time, as sent by devices
    expect(
      BacnetTimeStamp.fromValue(BacnetContextValue(0, bytes([12, 0, 0, 0]))),
      const BacnetTimeStampTime(_noon),
    );
    expect(() => BacnetTimeStamp.fromValue(_noon), _malformed());
    expect(
      () => BacnetTimeStamp.fromValue(BacnetContextValue(0, bytes([12]))),
      _malformed(),
    );
  });

  test('BacnetWeeklySchedule', () {
    final schedule = BacnetWeeklySchedule([
      for (var day = 0; day < 7; day++)
        day < 5
            ? const [
                BacnetTimeValue(_noon, BacnetReal(21)),
                BacnetTimeValue(_evening, BacnetNull()),
              ]
            : const <BacnetTimeValue>[],
    ]);
    expect(BacnetWeeklySchedule.fromValue(_wire(schedule.toValue())), schedule);
    expect(schedule[DateTime.monday], hasLength(2));
    expect(schedule[DateTime.sunday], isEmpty);
    expect(() => BacnetWeeklySchedule([[]]), throwsArgumentError);
    expect(
      () => BacnetWeeklySchedule.fromValue(
        BacnetList([
          for (var i = 0; i < 6; i++) const BacnetConstructedValue(0, []),
        ]),
      ),
      _malformed(),
    );
    expect(
      () => BacnetWeeklySchedule.fromValue(
        BacnetList([
          for (var i = 0; i < 7; i++)
            const BacnetConstructedValue(0, [BacnetReal(1)]),
        ]),
      ),
      _malformed(),
    );
  });

  test('BacnetCalendarEntry variants', () {
    final entries = <BacnetCalendarEntry>[
      const BacnetCalendarDate(_christmas),
      const BacnetCalendarDateRange(
        BacnetDateRange(
          BacnetDate(year: 2026, month: 7, day: 1),
          BacnetDate(year: 2026, month: 7, day: 31),
        ),
      ),
      const BacnetCalendarWeekNDay(
        BacnetWeekNDay(month: 12, weekOfMonth: 6, dayOfWeek: 5),
      ),
      const BacnetCalendarWeekNDay(BacnetWeekNDay(dayOfWeek: 7)),
    ];
    final value = BacnetList([for (final entry in entries) entry.toValue()]);
    expect(BacnetCalendarEntry.listFromValue(_wire(value)), entries);
    expect(
      () => BacnetCalendarEntry.fromValue(BacnetContextValue(2, bytes([1]))),
      _malformed(),
    );
  });

  test('BacnetSpecialEvent lists', () {
    final events = [
      BacnetSpecialEvent(
        period: const BacnetCalendarDate(_christmas),
        timeValues: const [BacnetTimeValue(_noon, BacnetReal(16))],
        priority: 5,
      ),
      BacnetSpecialEvent(
        period: const BacnetCalendarReference(
          BacnetObject(type: BacnetObjectType.calendar, instance: 1),
        ),
        timeValues: const [],
        priority: 16,
      ),
    ];
    final value = BacnetSpecialEvent.listToValue(events);
    expect(BacnetSpecialEvent.listFromValue(_wire(value)), events);
    expect(BacnetSpecialEvent.listFromValue(const BacnetList([])), isEmpty);
    expect(
      () => BacnetSpecialEvent(
        period: const BacnetCalendarDate(_christmas),
        timeValues: const [],
        priority: 17,
      ),
      throwsArgumentError,
    );
  });

  test('BacnetSpecialEvent encoding is accepted by bacnet-stack', () {
    // written to the Exception_Schedule of bacnet-stack's bacserv and read
    // back unchanged (tool/interop_client.dart)
    final writer = BacnetWriter();
    encodeApplicationValue(
      writer,
      BacnetSpecialEvent.listToValue([
        BacnetSpecialEvent(
          period: const BacnetCalendarDate(
            BacnetDate(year: 2026, month: 12, day: 25),
          ),
          timeValues: const [
            BacnetTimeValue(
              BacnetTime(hour: 8, minute: 0, second: 0, hundredths: 0),
              BacnetReal(16),
            ),
          ],
          priority: 5,
        ),
      ]),
    );
    expect(
      hex(writer.toBytes()),
      '0e 0c 7e 0c 19 ff 0f 2e b4 08 00 00 00 44 41 80 00 00 2f 39 05',
    );
  });

  test('BacnetDeviceObjectPropertyReference', () {
    final references = [
      const BacnetDeviceObjectPropertyReference(
        object: _ai1,
        property: BacnetPropertyId.presentValue,
        device: _device,
      ),
      const BacnetDeviceObjectPropertyReference(
        object: _ai1,
        property: BacnetPropertyId.priorityArray,
        arrayIndex: 8,
      ),
      const BacnetDeviceObjectPropertyReference(
        object: _ai1,
        property: BacnetPropertyId.statusFlags,
      ),
    ];
    final value = BacnetDeviceObjectPropertyReference.listToValue(references);
    expect(
      BacnetDeviceObjectPropertyReference.listFromValue(_wire(value)),
      references,
    );
    expect(
      BacnetDeviceObjectPropertyReference.fromValue(
        _wire(references.first.toValue()),
      ),
      references.first,
    );
    expect(
      () => BacnetDeviceObjectPropertyReference.fromValue(_wire(value)),
      _malformed(),
      reason: 'three references where one is expected',
    );
  });

  test('BacnetAddressBinding', () {
    final value = BacnetList([
      _device,
      const BacnetUnsigned(0),
      BacnetOctetString(bytes([192, 168, 1, 10, 0xBA, 0xC0])),
      const BacnetObject(type: BacnetObjectType.device, instance: 7),
      const BacnetUnsigned(5),
      BacnetOctetString(bytes([0x22])),
    ]);
    final bindings = BacnetAddressBinding.listFromValue(_wire(value));
    expect(bindings, hasLength(2));
    expect(bindings.first.device, _device);
    expect(bindings.first.ipAddress, '192.168.1.10');
    expect(bindings.first.port, 47808);
    expect(bindings.last.network, 5);
    expect(bindings.last.ipAddress, isNull);
    expect(
      () => BacnetAddressBinding.listFromValue(const BacnetList([_device])),
      _malformed(),
    );
  });

  test('bit string properties', () {
    const bits = BacnetEventTransitionBits(toOffNormal: true, toNormal: true);
    expect(BacnetEventTransitionBits.fromValue(_wire(bits.toValue())), bits);
    const limits = BacnetLimitEnable(highLimit: true);
    expect(BacnetLimitEnable.fromValue(_wire(limits.toValue())), limits);
    expect(
      () => BacnetLimitEnable.fromValue(const BacnetUnsigned(1)),
      _malformed(),
    );
  });

  test('BacnetPriorityArray', () {
    final slots = [
      for (var i = 1; i <= 16; i++)
        i == 8 ? const BacnetReal(21.5) : const BacnetNull(),
    ];
    final array = BacnetPriorityArray.fromValue(_wire(BacnetList(slots)));
    expect(array.activePriority, 8);
    expect(array.activeValue, const BacnetReal(21.5));
    expect(array[8], const BacnetReal(21.5));
    expect(array[1], const BacnetNull());
    final idle = BacnetPriorityArray(List.filled(16, const BacnetNull()));
    expect(idle.activePriority, isNull);
    expect(idle.activeValue, isNull);
    expect(
      () => BacnetPriorityArray.fromValue(const BacnetList([BacnetNull()])),
      _malformed(),
    );
  });
}
