/*
 * libFuzzer target for the engine: feeds network packets (NPDUs, after the
 * BVLC header) through the receive path of bacnet_plugin_poll(), with the
 * server enabled (objects of many types, schedules, trend logs, files,
 * channels, backup) and one confirmed request of the client outstanding.
 *
 * Input: one control byte, then the NPDU.
 *   bit 0    the packet comes from the bound device (else another address)
 *   bit 1    the APDU of a reply gets the invoke id of the open request
 *   bits 2-4 the open request (ReadProperty, ReadPropertyMultiple, ...)
 *
 * Built and run by tool/fuzz_native.dart.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bacnet_plugin.h"
#include "bp_internal.h"
#include "bacnet/basic/tsm/tsm.h"

#define FUZZ_DEVICE 1234u
#define FUZZ_REMOTE 77u

static uint8_t Open_Invoke_Id;

/* the open requests: service and request after the service choice */
static const struct {
    uint8_t service;
    uint8_t data[16];
    uint8_t length;
} Requests[] = {
    /* ReadProperty analog-input 1 present-value */
    { 12, { 0x0C, 0x00, 0x00, 0x00, 0x01, 0x19, 0x55 }, 7 },
    /* ReadPropertyMultiple analog-input 1 all */
    { 14, { 0x0C, 0x00, 0x00, 0x00, 0x01, 0x1E, 0x09, 0x08, 0x1F }, 9 },
    /* ReadRange trend-log 1 log-buffer */
    { 26, { 0x0C, 0x05, 0x00, 0x00, 0x01, 0x19, 0x83 }, 7 },
    /* AtomicReadFile file 1 stream 0 100 */
    { 6, { 0xC4, 0x02, 0x80, 0x00, 0x01, 0x0E, 0x31, 0x00, 0x21, 0x64, 0x0F },
      11 },
    /* SubscribeCOVPropertyMultiple */
    { 30,
      { 0x09, 0x01, 0x4E, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x1E, 0x0E, 0x09,
        0x55, 0x0F, 0x29, 0x00, 0x1F },
      16 },
    /* GetEventInformation */
    { 29, { 0 }, 0 },
    /* CreateObject analog-value */
    { 10, { 0x0E, 0x09, 0x02, 0x0F }, 4 },
    /* ConfirmedPrivateTransfer vendor 260 service 1 */
    { 18, { 0x0A, 0x01, 0x04, 0x19, 0x01 }, 5 },
};

static void fuzz_setup(void)
{
    static const uint32_t backup_files[] = { 1 };
    const uint16_t types[] = {
        OBJECT_ANALOG_INPUT,      OBJECT_ANALOG_OUTPUT,
        OBJECT_ANALOG_VALUE,      OBJECT_BINARY_INPUT,
        OBJECT_BINARY_OUTPUT,     OBJECT_BINARY_VALUE,
        OBJECT_MULTI_STATE_INPUT, OBJECT_MULTI_STATE_OUTPUT,
        OBJECT_MULTI_STATE_VALUE, OBJECT_NOTIFICATION_CLASS,
        OBJECT_FILE,              OBJECT_SCHEDULE,
        OBJECT_CALENDAR,          OBJECT_TRENDLOG,
        OBJECT_CHANNEL,           OBJECT_INTEGER_VALUE,
        OBJECT_POSITIVE_INTEGER_VALUE, OBJECT_CHARACTERSTRING_VALUE,
        OBJECT_OCTETSTRING_VALUE, OBJECT_BITSTRING_VALUE,
        OBJECT_TIME_VALUE,        OBJECT_TIMER,
        OBJECT_LOOP,              OBJECT_LIGHTING_OUTPUT,
        OBJECT_BINARY_LIGHTING_OUTPUT, OBJECT_COLOR,
        OBJECT_COLOR_TEMPERATURE, OBJECT_ACCUMULATOR,
        OBJECT_AVERAGING,         OBJECT_LOAD_CONTROL,
        OBJECT_STRUCTURED_VIEW,   OBJECT_LIFE_SAFETY_POINT,
        OBJECT_LIFE_SAFETY_ZONE,  OBJECT_PROGRAM,
        OBJECT_AUDIT_LOG,         OBJECT_ALERT_ENROLLMENT,
    };
    const char *iface = getenv("FUZZ_INTERFACE");
    uint16_t port = (uint16_t)(47900 + getpid() % 1000);
    uint32_t error_class, error_code;
    size_t i;

    if (bacnet_plugin_init(iface ? iface : "lo", port, BACNET_MAX_INSTANCE, 0) !=
        BP_OK) {
        fprintf(stderr, "fuzz: cannot open the BACnet/IP port %u\n", port);
        abort();
    }
    bacnet_plugin_server_enable(FUZZ_DEVICE, "fuzz");
    bacnet_plugin_device_set_password("fuzz");
    for (i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
        bacnet_plugin_object_create(types[i], 1, &error_class, &error_code);
        bacnet_plugin_object_create(types[i], 2, &error_class, &error_code);
    }
    bacnet_plugin_backup_configure(
        backup_files, 1, BP_BACKUP_PREPARE | BP_BACKUP_APPLY, 10);
    /* the device answering the open requests: 127.0.0.1:47807 */
    bacnet_plugin_bind_device(FUZZ_REMOTE, "127.0.0.1", 47807, 0, NULL, 0, 1476);
}

/* Ends every transaction and opens the request of kind. */
static void fuzz_open_request(unsigned kind)
{
    unsigned id;
    int32_t invoke_id;

    for (id = 0; id < 256; id++) {
        bp_transaction_t *tx = bp_tx_for((uint8_t)id);
        if (tx && tx->active) {
            bp_tx_end(tx);
            tsm_free_invoke_id((uint8_t)id);
        }
    }
    kind %= sizeof(Requests) / sizeof(Requests[0]);
    invoke_id = bacnet_plugin_send_confirmed(
        FUZZ_REMOTE, Requests[kind].service, Requests[kind].data,
        Requests[kind].length, 0);
    Open_Invoke_Id = invoke_id > 0 ? (uint8_t)invoke_id : 0;
}

/* Offset of the APDU in an NPDU, or 0 for a network layer message. */
static size_t fuzz_apdu_offset(const uint8_t *npdu, size_t length)
{
    size_t offset = 2;
    uint8_t control;

    if (length < 2) {
        return 0;
    }
    control = npdu[1];
    if (control & 0x80) {
        return 0;
    }
    if (control & 0x20) {
        if (offset + 3 > length) {
            return 0;
        }
        offset += 3 + npdu[offset + 2];
    }
    if (control & 0x08) {
        if (offset + 3 > length) {
            return 0;
        }
        offset += 3 + npdu[offset + 2];
    }
    if (control & 0x20) {
        offset += 1;
    }
    return offset < length ? offset : 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    static int ready;
    BACNET_ADDRESS src;
    uint8_t *npdu;
    size_t length, apdu;

    if (!ready) {
        fuzz_setup();
        ready = 1;
    }
    if (size < 1 || size - 1 > MAX_MPDU) {
        return 0;
    }
    fuzz_open_request((data[0] >> 2) & 0x07);
    length = size - 1;
    /* a copy of the exact size: reads past the packet are found */
    npdu = malloc(length ? length : 1);
    memcpy(npdu, data + 1, length);
    if (data[0] & 0x02) {
        apdu = fuzz_apdu_offset(npdu, length);
        if (apdu && apdu + 1 < length) {
            switch (npdu[apdu] >> 4) {
                case 2: /* SimpleACK */
                case 3: /* ComplexACK */
                case 4: /* SegmentACK */
                case 5: /* Error */
                case 6: /* Reject */
                case 7: /* Abort */
                    npdu[apdu + 1] = Open_Invoke_Id;
                    break;
                default:
                    break;
            }
        }
    }
    if (data[0] & 0x01) {
        uint8_t mac[MAX_MAC_LEN];
        uint8_t mac_len = 0;
        uint16_t net, max_apdu;

        memset(&src, 0, sizeof(src));
        if (bacnet_plugin_device_binding(
                FUZZ_REMOTE, mac, &mac_len, &net, &max_apdu) == 1) {
            memcpy(src.mac, mac, mac_len);
            src.mac_len = mac_len;
        }
    } else {
        static const uint8_t other[6] = { 10, 0, 0, 9, 0xBA, 0xC0 };
        memset(&src, 0, sizeof(src));
        memcpy(src.mac, other, sizeof(other));
        src.mac_len = sizeof(other);
    }
    bp_receive_packet(&src, npdu, (uint16_t)length);
    free(npdu);
    bacnet_plugin_events_clear();
    return 0;
}
