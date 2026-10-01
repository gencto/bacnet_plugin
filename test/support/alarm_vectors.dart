import 'dart:typed_data';

// Reference encodings produced by the encoders of bacnet-stack
// (event_notify_encode_service_request, alarm_ack_encode_service_request,
// getevent_information_ack_encode, get_alarm_summary_ack_encode_apdu_data,
// bacnet_destination_encode and list_element_encode_service_request).
const vectorOutOfRange =
    '09011c020000042c000000023e19103f49045964690589009901a900b903ce5e0c42a0'
    '33331a04802c3f8000003c42a000005fcf';
const vectorChangeOfState =
    '09071c020004d22c014000033e2ea47e0a0104b40c1e2d002f3f4901593269017d0c00'
    '50756d70206661696c656489019900a900b902ce1e0e19010f1a04801fcf';
const vectorAckNotification =
    '09071c020004d22c008000013e2ea47e0a0104b40c1e2d002f3f4901596469058902b9'
    '03';
const vectorBufferReady =
    '09031c020004d22c050000013e19053f490259c8690a89019900a900b900ceae0e0c05'
    '00000119833c020004d20f190a2914afcf';
const vectorChangeOfValue =
    '09091c020004d22c008000073e0c080f00003f49015978690289019900a900b900ce2e'
    '0e1c3fc000000f1a04002fcf';
const vectorUnsignedRange =
    '09091c020004d22c0c0000023e1a012c3f4901590a690b89009901a900b903cebe0a03'
    'e81a04802a0384bfcf';
const vectorAcknowledgeAlarm =
    '09071c0000000229033e19103f4d09006f70657261746f725e2ea47e0a0104b40d0000'
    '002f5f';
const vectorGetEventInformationAck =
    '0e0c0000000219032a05603e2ea47e0a0104b40c1e2d002f190019003f49005a05e06e'
    '2164216421c86f0c0140000319002a05c03e0c0100000019022ea47e0a0104b40e0000'
    '002f3f49015a05a06e2101210221036f0f1901';
const vectorGetAlarmSummaryAck = 'c4000000029103820560c400c0000991028205e0';
const vectorDestinationAddress =
    '8201feb400000000b4173b3b631e21006506c0a8010abac01f2105108205e0';
const vectorDestinationDevice =
    '8201f8b406000000b4121e00000c020004d2214d11820580';
const vectorAddListElement =
    '0c03c0000119663e8201feb400000000b4173b3b631e21006506c0a8010abac01f2105'
    '108205e03f';

/// The octets of a hex string.
Uint8List hexBytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);
