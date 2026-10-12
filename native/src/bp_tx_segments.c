/*
 * bacnet_plugin - transmission of segmented ComplexACKs (ASHRAE 135 clause
 * 5.4, responder in SEGMENTED_RESPONSE).
 *
 * The transaction state machine of bacnet-stack does not implement
 * segmentation (tsm.c: "not coded for segmentation"), so a response that does
 * not fit the requester's APDU is segmented here instead. The service handlers
 * that own their answer (ReadProperty, GetEnrollmentSummary, AuditLogQuery)
 * build a complete, unsegmented ComplexACK and hand it to
 * bp_tx_send_complex_ack(): it goes out as one datagram when it fits, is sliced
 * into windowed segments when the requester accepts segmentation, or is
 * answered with an Abort otherwise. Inbound SegmentACKs acknowledge windows and
 * drive retransmission; a window that is not acknowledged in time is resent and
 * the transfer is abandoned after a few attempts.
 *
 * This is the transmit mirror of bp_segments.c (which reassembles segmented
 * answers to our own requests).
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdlib.h>
#include <string.h>

#include "bacnet/abort.h"
#include "bacnet/basic/service/h_apdu.h"
#include "bacnet/basic/sys/mstimer.h"
#include "bacnet/basic/tsm/tsm.h"
#include "bacnet/bacenum.h"
#include "bacnet/npdu.h"

#include "bp_internal.h"

/* ComplexACK / SegmentACK flag bits (ASHRAE 135 clause 20.1). */
#define BP_SEG_FLAG 0x08 /* ComplexACK: segmented-message */
#define BP_MOR_FLAG 0x04 /* ComplexACK: more-follows */
#define BP_NAK_FLAG 0x02 /* SegmentACK: negative acknowledgement */

/* Bytes of a segmented ComplexACK before the service-ack payload:
   PDU type + flags, invoke id, sequence number, window size, service choice. */
#define BP_SEG_HEADER 5

/* Acknowledgement is awaited for four segment timeouts before a window is
   retransmitted, matching the reassembly side (bp_segments.c). */
static uint32_t bp_tx_seg_timeout(void)
{
    return (uint32_t)apdu_timeout() * 4u;
}

void bp_tx_send_apdu(
    const BACNET_ADDRESS *dest,
    uint8_t priority,
    const uint8_t *apdu,
    uint32_t apdu_len)
{
    uint8_t buffer[MAX_PDU];
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    BACNET_ADDRESS to;
    int pdu_len;

    if (apdu_len == 0 || apdu_len > MAX_APDU) {
        return;
    }
    bacnet_address_copy(&to, dest);
    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(&npdu_data, false, (BACNET_MESSAGE_PRIORITY)priority);
    pdu_len = npdu_encode_pdu(&buffer[0], &to, &my_address, &npdu_data);
    if (pdu_len <= 0 || (uint32_t)pdu_len + apdu_len > sizeof(buffer)) {
        return;
    }
    memcpy(&buffer[pdu_len], apdu, apdu_len);
    (void)datalink_send_pdu(
        &to, &npdu_data, &buffer[0], (int)((uint32_t)pdu_len + apdu_len));
}

static void bp_tx_send_abort(
    const BACNET_ADDRESS *dest,
    uint8_t invoke_id,
    uint8_t reason,
    uint8_t priority)
{
    uint8_t apdu[8];
    int len = abort_encode_apdu(&apdu[0], invoke_id, reason, true);

    if (len > 0) {
        bp_tx_send_apdu(dest, priority, &apdu[0], (uint32_t)len);
    }
}

static bp_tx_seg_t *
bp_tx_seg_find(const BACNET_ADDRESS *src, uint8_t invoke_id)
{
    unsigned i;

    for (i = 0; i < BP_TX_SEG_SLOTS; i++) {
        bp_tx_seg_t *t = &bp_state.tx_seg[i];

        if (t->active && t->invoke_id == invoke_id &&
            bacnet_address_same(&t->dest, src)) {
            return t;
        }
    }
    return NULL;
}

static bp_tx_seg_t *bp_tx_seg_alloc(void)
{
    unsigned i;

    for (i = 0; i < BP_TX_SEG_SLOTS; i++) {
        if (!bp_state.tx_seg[i].active) {
            memset(&bp_state.tx_seg[i], 0, sizeof(bp_state.tx_seg[i]));
            return &bp_state.tx_seg[i];
        }
    }
    return NULL;
}

static void bp_tx_seg_free(bp_tx_seg_t *t)
{
    if (!t) {
        return;
    }
    if (t->active && bp_state.tx_segmenting) {
        bp_state.tx_segmenting--;
    }
    free(t->data);
    memset(t, 0, sizeof(*t));
}

/* Sends segment `seq` of the transfer. */
static void bp_tx_seg_send_one(const bp_tx_seg_t *t, uint8_t seq)
{
    uint8_t buffer[MAX_PDU];
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    BACNET_ADDRESS dest;
    int pdu_len;
    uint32_t offset = (uint32_t)seq * t->chunk;
    uint32_t n;
    bool more = (seq != (uint8_t)(t->count - 1));

    if (offset > t->length) {
        return;
    }
    n = t->length - offset;
    if (n > t->chunk) {
        n = t->chunk;
    }
    bacnet_address_copy(&dest, &t->dest);
    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(
        &npdu_data, false, (BACNET_MESSAGE_PRIORITY)t->priority);
    pdu_len = npdu_encode_pdu(&buffer[0], &dest, &my_address, &npdu_data);
    if (pdu_len <= 0 ||
        (uint32_t)pdu_len + BP_SEG_HEADER + n > sizeof(buffer)) {
        return;
    }
    buffer[pdu_len] = (uint8_t)(PDU_TYPE_COMPLEX_ACK | BP_SEG_FLAG |
                                (more ? BP_MOR_FLAG : 0));
    buffer[pdu_len + 1] = t->invoke_id;
    buffer[pdu_len + 2] = seq;
    buffer[pdu_len + 3] = t->window;
    buffer[pdu_len + 4] = t->service;
    if (n) {
        memcpy(&buffer[pdu_len + BP_SEG_HEADER], &t->data[offset], n);
    }
    (void)datalink_send_pdu(
        &dest, &npdu_data, &buffer[0],
        (int)((uint32_t)pdu_len + BP_SEG_HEADER + n));
}

/* Sends the outstanding window: segment 0 alone before the first ack, then
   the `window` segments that follow the last acknowledged sequence. Our own
   reassembler acknowledges segment 0 on its own and then at each window
   boundary (bp_segments.c), so the sender mirrors that cadence. */
static void bp_tx_seg_send_window(bp_tx_seg_t *t)
{
    uint8_t from;
    uint8_t to;
    uint8_t seq;

    if (t->acked == 0xFF) {
        from = 0;
        to = 0;
    } else {
        from = (uint8_t)(t->acked + 1);
        to = (uint8_t)(t->acked + t->window);
        if (to > (uint8_t)(t->count - 1)) {
            to = (uint8_t)(t->count - 1);
        }
    }
    for (seq = from;; seq++) {
        bp_tx_seg_send_one(t, seq);
        if (seq == to) {
            break;
        }
    }
    t->sent = to;
    t->deadline = (uint32_t)mstimer_now() + bp_tx_seg_timeout();
}

void bp_tx_send_complex_ack(
    const BACNET_ADDRESS *dest,
    const BACNET_CONFIRMED_SERVICE_DATA *service_data,
    const uint8_t *apdu,
    uint32_t apdu_len)
{
    uint8_t invoke_id = service_data->invoke_id;
    uint8_t priority = (uint8_t)service_data->priority;
    uint32_t max_apdu;
    uint32_t chunk;
    uint32_t count;
    uint32_t seg_limit;
    uint32_t payload_len;
    bp_tx_seg_t *t;

    /* Defensive: only a ComplexACK we built ourselves is segmentable. */
    if (apdu_len < 3 || apdu[0] != PDU_TYPE_COMPLEX_ACK) {
        return;
    }
    max_apdu = service_data->max_resp;
    if (max_apdu == 0 || max_apdu > MAX_APDU) {
        max_apdu = MAX_APDU;
    }
    /* Fits one APDU: send it unchanged, exactly as an unsegmented answer. */
    if (apdu_len <= max_apdu) {
        bp_tx_send_apdu(dest, priority, apdu, apdu_len);
        return;
    }
    /* Needs segmentation. */
    if (!bp_state.tx_segmentation || !service_data->segmented_response_accepted ||
        max_apdu <= BP_SEG_HEADER) {
        bp_tx_send_abort(
            dest, invoke_id, ABORT_REASON_SEGMENTATION_NOT_SUPPORTED, priority);
        return;
    }
    payload_len = apdu_len - 3u; /* service-ack data after type/invoke/choice */
    chunk = max_apdu - BP_SEG_HEADER;
    count = (payload_len + chunk - 1u) / chunk;
    /* The requester's advertised segment budget (0 or ">64" means unstated:
       fall back to our own cap). */
    {
        uint32_t max_segs = service_data->max_segs > 0
            ? (uint32_t)service_data->max_segs
            : 0u;
        seg_limit = (max_segs >= 2u && max_segs <= BP_TX_SEG_MAX_COUNT)
            ? max_segs
            : BP_TX_SEG_MAX_COUNT;
    }
    if (payload_len > BP_TX_SEG_MAX_BYTES || count > seg_limit ||
        count > BP_TX_SEG_MAX_COUNT) {
        bp_tx_send_abort(
            dest, invoke_id, ABORT_REASON_BUFFER_OVERFLOW, priority);
        return;
    }
    t = bp_tx_seg_alloc();
    if (!t) {
        bp_tx_send_abort(
            dest, invoke_id, ABORT_REASON_OUT_OF_RESOURCES, priority);
        return;
    }
    t->data = (uint8_t *)malloc(payload_len);
    if (!t->data) {
        bp_tx_send_abort(
            dest, invoke_id, ABORT_REASON_OUT_OF_RESOURCES, priority);
        return;
    }
    memcpy(t->data, &apdu[3], payload_len);
    t->length = payload_len;
    t->chunk = (uint16_t)chunk;
    t->count = (uint8_t)count;
    t->window = count < BP_TX_SEG_WINDOW ? (uint8_t)count : BP_TX_SEG_WINDOW;
    if (t->window < 1) {
        t->window = 1;
    }
    t->invoke_id = invoke_id;
    t->service = apdu[2];
    t->priority = priority;
    t->acked = 0xFF;
    t->sent = 0;
    t->retries = 0;
    bacnet_address_copy(&t->dest, dest);
    t->active = true;
    bp_state.tx_segmenting++;
    bp_state.stats.segmented_sent++;
    bp_tx_seg_send_window(t); /* kicks off with segment 0 */
}

bool bp_tx_segment_ack(
    const BACNET_ADDRESS *src, const uint8_t *apdu, uint16_t apdu_len)
{
    bp_tx_seg_t *t;
    bool negative;
    uint8_t invoke_id;
    uint8_t sequence;

    /* PDU type, invoke id, sequence number, window size. */
    if (apdu_len < 4) {
        return false;
    }
    negative = (apdu[0] & BP_NAK_FLAG) != 0;
    invoke_id = apdu[1];
    sequence = apdu[2];
    t = bp_tx_seg_find(src, invoke_id);
    if (!t) {
        return false; /* not one of our responder transfers */
    }
    if (negative) {
        /* The receiver got everything up to `sequence`; resend from there. A
           retransmission counts against the retry budget to stop a loop. */
        t->acked = sequence;
        if (++t->retries > BP_TX_SEG_RETRIES) {
            bp_tx_seg_free(t);
            bp_state.stats.timeouts++;
        } else {
            bp_tx_seg_send_window(t);
        }
        return true;
    }
    if (sequence == (uint8_t)(t->count - 1)) {
        /* final segment acknowledged: the transfer is complete */
        bp_tx_seg_free(t);
        return true;
    }
    if (sequence != t->sent) {
        /* duplicate or stale acknowledgement: keep waiting */
        return true;
    }
    t->acked = sequence;
    t->retries = 0;
    bp_tx_seg_send_window(t);
    return true;
}

void bp_tx_segments_timer(uint32_t now)
{
    unsigned i;

    if (bp_state.tx_segmenting == 0) {
        return;
    }
    for (i = 0; i < BP_TX_SEG_SLOTS; i++) {
        bp_tx_seg_t *t = &bp_state.tx_seg[i];

        if (t->active && (int32_t)(now - t->deadline) >= 0) {
            if (++t->retries > BP_TX_SEG_RETRIES) {
                bp_tx_seg_free(t);
                bp_state.stats.timeouts++;
            } else {
                bp_tx_seg_send_window(t); /* retransmit the current window */
            }
        }
    }
}

void bp_tx_segments_reset(void)
{
    unsigned i;

    for (i = 0; i < BP_TX_SEG_SLOTS; i++) {
        free(bp_state.tx_seg[i].data);
        memset(&bp_state.tx_seg[i], 0, sizeof(bp_state.tx_seg[i]));
    }
    bp_state.tx_segmenting = 0;
}
