import 'dart:typed_data';

import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:bacnet_plugin/src/codec/requests.dart';
import 'package:bacnet_plugin/src/codec/responses.dart';
import 'package:bacnet_plugin/src/codec/value_encoding.dart' show contextValue;
import 'package:test/test.dart';

import '../support/alarm_vectors.dart';
import '../support/codec_helpers.dart';

String _hex(Uint8List data) =>
    data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

final _octoberFirst = BacnetTimeStampDateTime(
  BacnetDateTime.fromDateTime(DateTime(2026, 10, 1, 12, 30, 45)),
);

const _inAlarm = BacnetStatusFlags(inAlarm: true);

/// Decodes [hex], checks it re-encodes to the same octets and returns it.
EventNotificationEvent _notification(String hex) {
  final event = decodeEventNotification(hexBytes(hex));
  expect(_hex(encodeEventNotification(event)), hex);
  return event;
}

void main() {
  group('event notifications', () {
    test('out of range with a sequence time stamp', () {
      final event = _notification(vectorOutOfRange);
      expect(event.processId, 1);
      expect(event.deviceId, 4);
      expect(
        event.object,
        const BacnetObject(type: BacnetObjectType.analogInput, instance: 2),
      );
      expect(event.timeStamp, const BacnetTimeStampSequence(16));
      expect(event.notificationClass, 4);
      expect(event.priority, 100);
      expect(event.eventType, BacnetEventType.outOfRange);
      expect(event.messageText, isNull);
      expect(event.notifyType, BacnetNotifyType.alarm);
      expect(event.ackRequired, isTrue);
      expect(event.fromState, BacnetEventState.normal);
      expect(event.toState, BacnetEventState.highLimit);
      expect(event.isAckNotification, isFalse);
      final values = event.eventValues! as BacnetOutOfRangeValues;
      expect(values.exceedingValue, closeTo(80.1, 1e-5));
      expect(values.statusFlags, _inAlarm);
      expect(values.deadband, 1);
      expect(values.exceededLimit, 80);
    });

    test('change of state with a date-time stamp and a message', () {
      final event = _notification(vectorChangeOfState);
      expect(event.timeStamp, _octoberFirst);
      expect(event.messageText, 'Pump failed');
      expect(event.notifyType, BacnetNotifyType.event);
      expect(event.ackRequired, isFalse);
      expect(event.toState, BacnetEventState.offNormal);
      switch (event.eventValues) {
        case BacnetChangeOfStateValues(:final newState, :final statusFlags):
          expect(newState.kind, BacnetPropertyStateKind.binaryValue);
          expect(newState.asBinaryPV, BacnetBinaryPV.active);
          expect(newState.asEventState, isNull);
          expect(statusFlags, _inAlarm);
        default:
          fail('unexpected ${event.eventValues}');
      }
    });

    test('acknowledgement notification without values', () {
      final event = _notification(vectorAckNotification);
      expect(event.isAckNotification, isTrue);
      expect(event.toState, BacnetEventState.highLimit);
      expect(event.fromState, isNull);
      expect(event.ackRequired, isFalse);
      expect(event.eventValues, isNull);
    });

    test('buffer ready', () {
      final event = _notification(vectorBufferReady);
      expect(
        event.eventValues,
        const BacnetBufferReadyValues(
          bufferProperty: BacnetDeviceObjectPropertyReference(
            object: BacnetObject(type: BacnetObjectType.trendLog, instance: 1),
            property: BacnetPropertyId.logBuffer,
            device: BacnetObject(type: BacnetObjectType.device, instance: 1234),
          ),
          previousNotification: 10,
          currentNotification: 20,
        ),
      );
      expect(event.eventValues!.statusFlags, isNull);
    });

    test('change of value with a time of day stamp', () {
      final event = _notification(vectorChangeOfValue);
      expect(
        event.timeStamp,
        const BacnetTimeStampTime(
          BacnetTime(hour: 8, minute: 15, second: 0, hundredths: 0),
        ),
      );
      expect(
        event.eventValues,
        const BacnetChangeOfValueValues.value(
          1.5,
          statusFlags: BacnetStatusFlags(),
        ),
      );
    });

    test('unsigned range', () {
      final event = _notification(vectorUnsignedRange);
      expect(event.timeStamp, const BacnetTimeStampSequence(300));
      expect(
        event.eventValues,
        const BacnetUnsignedRangeValues(
          exceedingValue: 1000,
          statusFlags: _inAlarm,
          exceededLimit: 900,
        ),
      );
    });

    test('malformed event values are kept as other values', () {
      // out of range whose deadband is an Unsigned instead of a REAL
      final data = hexBytes(
        vectorOutOfRange.replaceFirst('2c3f800000', '2901'),
      );
      final event = decodeEventNotification(data);
      expect(event.eventValues, isA<BacnetOtherEventValues>());
      expect(event.eventValues!.eventType, BacnetEventType.outOfRange);
    });

    test('truncated notifications are rejected', () {
      final data = hexBytes(vectorOutOfRange);
      // the event values [12] are optional: the notification ends before
      final withoutValues = vectorOutOfRange.indexOf('ce5e') ~/ 2;
      for (var length = 0; length < data.length; length++) {
        final prefix = Uint8List.sublistView(data, 0, length);
        if (length == withoutValues) {
          expect(decodeEventNotification(prefix).eventValues, isNull);
          continue;
        }
        expect(
          () => decodeEventNotification(prefix),
          throwsA(isA<BacnetDecodeException>()),
          reason: 'length $length',
        );
      }
    });
  });

  group('event values', () {
    const flags = BacnetStatusFlags(fault: true, outOfService: true);
    final all = <BacnetEventValues>[
      const BacnetChangeOfBitstringValues(
        referencedBitstring: BacnetBitString([true, false, true]),
        statusFlags: flags,
      ),
      const BacnetChangeOfStateValues(
        newState: BacnetPropertyState.unsigned(3),
        statusFlags: flags,
      ),
      const BacnetChangeOfStateValues(
        newState: BacnetPropertyState.boolean(true),
        statusFlags: flags,
      ),
      const BacnetChangeOfStateValues(
        newState: BacnetPropertyState.integer(-5),
        statusFlags: flags,
      ),
      const BacnetChangeOfValueValues.bits(
        BacnetBitString([false, true]),
        statusFlags: flags,
      ),
      const BacnetChangeOfValueValues.value(-2.5, statusFlags: flags),
      const BacnetCommandFailureValues(
        commandValue: BacnetEnumerated(1),
        statusFlags: flags,
        feedbackValue: BacnetEnumerated(0),
      ),
      const BacnetFloatingLimitValues(
        referenceValue: 25,
        statusFlags: flags,
        setpointValue: 21,
        errorLimit: 3,
      ),
      const BacnetOutOfRangeValues(
        exceedingValue: -10,
        statusFlags: flags,
        deadband: 0.5,
        exceededLimit: -5,
      ),
      const BacnetChangeOfLifeSafetyValues(
        newState: 2,
        newMode: 1,
        statusFlags: flags,
        operationExpected: 3,
      ),
      const BacnetUnsignedRangeValues(
        exceedingValue: 7,
        statusFlags: flags,
        exceededLimit: 5,
      ),
      const BacnetDoubleOutOfRangeValues(
        exceedingValue: 1e10,
        statusFlags: flags,
        deadband: 0.001,
        exceededLimit: 9e9,
      ),
      const BacnetSignedOutOfRangeValues(
        exceedingValue: -300,
        statusFlags: flags,
        deadband: 2,
        exceededLimit: -200,
      ),
      const BacnetUnsignedOutOfRangeValues(
        exceedingValue: 70000,
        statusFlags: flags,
        deadband: 10,
        exceededLimit: 65535,
      ),
      const BacnetChangeOfCharacterStringValues(
        changedValue: 'Störung',
        statusFlags: flags,
        alarmValue: 'Störung',
      ),
      const BacnetChangeOfStatusFlagsValues(
        referencedFlags: flags,
        presentValue: BacnetReal(4),
      ),
      const BacnetChangeOfStatusFlagsValues(referencedFlags: flags),
      const BacnetChangeOfReliabilityValues(
        reliability: BacnetReliability.overRange,
        statusFlags: flags,
        propertyValues: [
          BacnetPropertyValue(
            propertyIdentifier: BacnetPropertyId.presentValue,
            value: BacnetReal(120),
          ),
          BacnetPropertyValue(
            propertyIdentifier: BacnetPropertyId.priorityArray,
            propertyArrayIndex: 8,
            value: BacnetNull(),
            priority: 8,
          ),
        ],
      ),
      BacnetOtherEventValues(BacnetEventType.changeOfTimer, [
        contextValue(0, const BacnetEnumerated(1)),
      ]),
    ];

    for (final values in all) {
      test('${values.runtimeType} round trips', () {
        final decoded = BacnetEventValues.fromValue(
          roundTrip(values.toValue()),
        );
        expect(decoded, values);
        expect(decoded.runtimeType, values.runtimeType);
        expect(decoded.eventType, values.eventType);
      });
    }

    test('reports the status flags of the algorithm', () {
      expect(all.first.statusFlags, flags);
      expect(
        const BacnetChangeOfStatusFlagsValues(
          referencedFlags: _inAlarm,
        ).statusFlags,
        _inAlarm,
      );
    });

    test('rejects values that are not a choice', () {
      expect(
        () => BacnetEventValues.fromValue(const BacnetReal(1)),
        throwsA(isA<BacnetDecodeException>()),
      );
      expect(
        () => BacnetEventValues.fromValue(
          const BacnetConstructedValue(5, [BacnetReal(1)]),
        ),
        throwsA(isA<BacnetDecodeException>()),
      );
    });
  });

  group('property states', () {
    test('decode by kind', () {
      expect(
        BacnetPropertyState.fromValue(
          contextValue(0, const BacnetBoolean(true)),
        ).asBoolean,
        isTrue,
      );
      expect(
        BacnetPropertyState.fromValue(
          contextValue(41, const BacnetSigned(-7)),
        ).asInteger,
        -7,
      );
      final state = BacnetPropertyState.fromValue(
        contextValue(8, const BacnetEnumerated(3)),
      );
      expect(
        state,
        const BacnetPropertyState.eventState(BacnetEventState.highLimit),
      );
      expect(state.asEventState, BacnetEventState.highLimit);
      expect(state.asBinaryPV, isNull);
      expect(state.toString(), contains('High Limit'));
    });

    test('reject other values', () {
      expect(
        () => BacnetPropertyState.fromValue(const BacnetEnumerated(1)),
        throwsA(isA<BacnetDecodeException>()),
      );
    });
  });

  group('alarm services', () {
    test('AcknowledgeAlarm', () {
      final data = encodeAcknowledgeAlarm(
        processId: 7,
        object: const BacnetObject(
          type: BacnetObjectType.analogInput,
          instance: 2,
        ),
        eventState: BacnetEventState.highLimit,
        timeStamp: const BacnetTimeStampSequence(16),
        source: 'operator',
        timeOfAcknowledgment: BacnetTimeStampDateTime(
          BacnetDateTime.fromDateTime(DateTime(2026, 10, 1, 13)),
        ),
      );
      expect(_hex(data), vectorAcknowledgeAlarm);
    });

    test('AcknowledgeAlarm requests decode', () {
      final ack = decodeAcknowledgeAlarm(hexBytes(vectorAcknowledgeAlarm));
      expect(ack.processId, 7);
      expect(
        ack.object,
        const BacnetObject(type: BacnetObjectType.analogInput, instance: 2),
      );
      expect(ack.eventState, BacnetEventState.highLimit);
      expect(ack.timeStamp, const BacnetTimeStampSequence(16));
      expect(ack.source, 'operator');
      expect(
        ack.timeOfAcknowledgment,
        BacnetTimeStampDateTime(
          BacnetDateTime.fromDateTime(DateTime(2026, 10, 1, 13)),
        ),
      );
    });

    test('AddListElement requests decode', () {
      final list = decodeListElements(hexBytes(vectorAddListElement));
      expect(
        list.object,
        const BacnetObject(
          type: BacnetObjectType.notificationClass,
          instance: 1,
        ),
      );
      expect(list.propertyId, BacnetPropertyId.recipientList);
      expect(list.arrayIndex, -1);
      expect(BacnetProperties.recipientList.decode(list.elements), [
        BacnetDestination(
          recipient: BacnetRecipient.ip('192.168.1.10', 47808),
          processId: 5,
        ),
      ]);
    });

    test('GetEventInformation', () {
      expect(encodeGetEventInformation(), isEmpty);
      expect(
        _hex(
          encodeGetEventInformation(
            lastReceived: const BacnetObject(
              type: BacnetObjectType.analogInput,
              instance: 2,
            ),
          ),
        ),
        '0c00000002',
      );
    });

    test('GetEventInformation-ACK', () {
      final result = decodeGetEventInformationAck(
        hexBytes(vectorGetEventInformationAck),
      );
      expect(result.moreEvents, isTrue);
      expect(result.summaries, hasLength(2));
      final [first, second] = result.summaries;
      expect(
        first.object,
        const BacnetObject(type: BacnetObjectType.analogInput, instance: 2),
      );
      expect(first.eventState, BacnetEventState.highLimit);
      expect(
        first.acknowledgedTransitions,
        const BacnetEventTransitionBits(toFault: true, toNormal: true),
      );
      expect(first.eventTimeStamps, [
        _octoberFirst,
        const BacnetTimeStampSequence(0),
        const BacnetTimeStampSequence(0),
      ]);
      expect(first.notifyType, BacnetNotifyType.alarm);
      expect(
        first.eventEnable,
        const BacnetEventTransitionBits(
          toOffNormal: true,
          toFault: true,
          toNormal: true,
        ),
      );
      expect(first.eventPriorities, [100, 100, 200]);
      expect(first.stateTimeStamp, _octoberFirst);
      expect(first.isUnacknowledged, isTrue);

      expect(second.eventState, BacnetEventState.normal);
      expect(second.notifyType, BacnetNotifyType.event);
      expect(second.eventPriorities, [1, 2, 3]);
      expect(second.stateTimeStamp, isA<BacnetTimeStampDateTime>());
      expect(second.isUnacknowledged, isTrue);
      expect(second.eventTimeStamps.first, isA<BacnetTimeStampTime>());
    });

    test('GetAlarmSummary-ACK', () {
      final summaries = decodeGetAlarmSummaryAck(
        hexBytes(vectorGetAlarmSummaryAck),
      );
      expect(summaries, [
        const BacnetAlarmSummary(
          object: BacnetObject(type: BacnetObjectType.analogInput, instance: 2),
          alarmState: BacnetEventState.highLimit,
          acknowledgedTransitions: BacnetEventTransitionBits(
            toFault: true,
            toNormal: true,
          ),
        ),
        const BacnetAlarmSummary(
          object: BacnetObject(type: BacnetObjectType.binaryInput, instance: 9),
          alarmState: BacnetEventState.offNormal,
          acknowledgedTransitions: BacnetEventTransitionBits(
            toOffNormal: true,
            toFault: true,
            toNormal: true,
          ),
        ),
      ]);
      expect(decodeGetAlarmSummaryAck(Uint8List(0)), isEmpty);
      expect(
        () => decodeGetAlarmSummaryAck(hexBytes('c400000002')),
        throwsA(isA<BacnetDecodeException>()),
      );
    });
  });

  group('recipients', () {
    final address = BacnetDestination(
      recipient: BacnetRecipient.ip('192.168.1.10', 47808),
      processId: 5,
    );
    final device = BacnetDestination(
      recipient: const BacnetRecipient.device(1234),
      validDays: BacnetDaysOfWeek.workdays,
      fromTime: const BacnetTime(hour: 6, minute: 0, second: 0, hundredths: 0),
      toTime: const BacnetTime(hour: 18, minute: 30, second: 0, hundredths: 0),
      processId: 77,
      issueConfirmedNotifications: true,
      transitions: const BacnetEventTransitionBits(toOffNormal: true),
    );

    BacnetValue encoded(BacnetValue value) {
      final writer = BacnetWriter();
      encodeApplicationValue(writer, value);
      return decodeApplicationData(writer.toBytes());
    }

    String hexOf(BacnetValue value) {
      final writer = BacnetWriter();
      encodeApplicationValue(writer, value);
      return _hex(writer.toBytes());
    }

    test('encode like bacnet-stack', () {
      expect(hexOf(address.toValue()), vectorDestinationAddress);
      expect(hexOf(device.toValue()), vectorDestinationDevice);
    });

    test('decode a Recipient_List', () {
      final list = BacnetDestination.listFromValue(
        decodeApplicationData(
          hexBytes(vectorDestinationAddress + vectorDestinationDevice),
        ),
      );
      expect(list, [address, device]);
      final [first, second] = list;
      expect(first.recipient, isA<BacnetAddressRecipient>());
      final recipient = first.recipient as BacnetAddressRecipient;
      expect(recipient.ipAddress, '192.168.1.10');
      expect(recipient.port, 47808);
      expect(recipient.network, 0);
      expect(second.recipient, const BacnetRecipient.device(1234));
      expect(second.validDays.weekdays, [1, 2, 3, 4, 5]);
      expect(
        BacnetDestination.listFromValue(
          encoded(BacnetDestination.listToValue(list)),
        ),
        list,
      );
      expect(
        BacnetDestination.listFromValue(encoded(const BacnetList([]))),
        isEmpty,
      );
    });

    test('reject malformed lists', () {
      expect(
        () => BacnetDestination.listFromValue(
          decodeApplicationData(
            hexBytes(vectorDestinationAddress.substring(2)),
          ),
        ),
        throwsA(isA<BacnetDecodeException>()),
      );
    });

    test('AddListElement request', () {
      final data = encodeListElements(
        BacnetObjectType.notificationClass,
        1,
        BacnetPropertyId.recipientList,
        BacnetDestination.listToValue([address]),
      );
      expect(_hex(data), vectorAddListElement);
    });

    test('IP recipients are validated', () {
      expect(() => BacnetRecipient.ip('192.168.1', 47808), throwsArgumentError);
      expect(
        () => BacnetRecipient.ip('192.168.1.300', 47808),
        throwsArgumentError,
      );
      expect(() => BacnetRecipient.ip('10.0.0.1', 70000), throwsArgumentError);
      expect(
        BacnetRecipient.ip('10.0.0.1', 47808, network: 5),
        BacnetAddressRecipient(network: 5, mac: [10, 0, 0, 1, 0xBA, 0xC0]),
      );
    });

    test('days of week', () {
      final weekend = BacnetDaysOfWeek([DateTime.saturday, DateTime.sunday]);
      expect(weekend.contains(DateTime.sunday), isTrue);
      expect(weekend.contains(DateTime.monday), isFalse);
      expect(
        weekend.toBitString(),
        const BacnetBitString([false, false, false, false, false, true, true]),
      );
      expect(BacnetDaysOfWeek.fromBitString(weekend.toBitString()), weekend);
      expect(BacnetDaysOfWeek.all.weekdays, hasLength(7));
      expect(() => BacnetDaysOfWeek([0]), throwsRangeError);
    });
  });

  group('notification class properties', () {
    test('Priority', () {
      const priorities = BacnetEventPriorities(
        toOffNormal: 10,
        toFault: 20,
        toNormal: 30,
      );
      expect(
        BacnetProperties.priority.decode(
          roundTrip(BacnetProperties.priority.encode(priorities)),
        ),
        priorities,
      );
      expect(priorities[BacnetEventTransition.toFault], 20);
      expect(
        () => BacnetProperties.priority.decode(const BacnetUnsigned(1)),
        throwsA(isA<BacnetDecodeException>()),
      );
    });

    test('Ack_Required and Notify_Type', () {
      expect(
        BacnetProperties.ackRequired.decode(
          const BacnetBitString([true, false, true]),
        ),
        const BacnetEventTransitionBits(toOffNormal: true, toNormal: true),
      );
      expect(
        BacnetProperties.notifyType.decode(const BacnetEnumerated(1)),
        BacnetNotifyType.event,
      );
    });

    test('transitions into states', () {
      expect(
        BacnetEventTransition.into(BacnetEventState.normal),
        BacnetEventTransition.toNormal,
      );
      expect(
        BacnetEventTransition.into(BacnetEventState.fault),
        BacnetEventTransition.toFault,
      );
      expect(
        BacnetEventTransition.into(BacnetEventState.lowLimit),
        BacnetEventTransition.toOffNormal,
      );
    });
  });
}
