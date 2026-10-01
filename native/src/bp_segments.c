/*
 * bacnet_plugin - reception of segmented ComplexACKs (ASHRAE 135 clause
 * 5.4.4, client in SEGMENTED_CONFIRMATION).
 *
 * The transaction state machine of bacnet-stack does not implement
 * segmentation, so segmented answers to our confirmed requests are taken
 * out of the receive path before the stack sees them: segments are
 * acknowledged window by window, reassembled and reported as one
 * BP_EVENT_COMPLEX_ACK. While a transaction receives segments its invoke id
 * stays reserved in the TSM without retransmission timers.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdlib.h>
#include <string.h>

#include "bacnet/abort.h"
#include "bacnet/basic/service/h_apdu.h"
#include "bacnet/basic/sys/mstimer.h"
#include "bacnet/basic/tsm/tsm.h"
#include "bacnet/npdu.h"
#include "bacnet/segmentack.h"

#include "bp_internal.h"

/* Event payloads are limited to 64 KiB. */
#define BP_SEGMENTS_MAX_BYTES 65000u

struct bp_segments {
    uint8_t *data;
    uint32_t length;
    uint32_t capacity;
    /* sequence number of the last segment received in order */
    uint8_t last;
    /* first sequence number of the current window */
    uint8_t initial;
    /* window size proposed by the server */
    uint8_t window;
    uint32_t deadline;
};

static uint32_t bp_segment_timeout(void)
{
    /* the server retransmits a window after the segment timeout; give up
       when nothing arrives for four of them (Tseg * 4) */
    return (uint32_t)apdu_timeout() * 4u;
}

/* Keeps the invoke id reserved in the TSM without retry timers: the
   transaction is answered, only the remaining segments are missing. */
static void bp_tsm_hold(uint8_t invoke_id)
{
    tsm_free_invoke_id(invoke_id);
    tsm_invokeID_set(invoke_id);
    (void)tsm_next_free_invokeID();
    /* continue the invoke id rotation where our requests left it */
    tsm_invokeID_set((uint8_t)(bp_state.last_invoke_id + 1));
}

static void
bp_send_apdu(const bp_transaction_t *tx, const uint8_t *apdu, int len)
{
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    BACNET_ADDRESS dest;
    uint8_t buffer[MAX_NPDU + 16];
    int pdu_len;

    if (len <= 0 || len > 16) {
        return;
    }
    bacnet_address_copy(&dest, &tx->dest);
    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(&npdu_data, false, MESSAGE_PRIORITY_NORMAL);
    pdu_len = npdu_encode_pdu(&buffer[0], &dest, &my_address, &npdu_data);
    if (pdu_len <= 0) {
        return;
    }
    memcpy(&buffer[pdu_len], apdu, (size_t)len);
    (void)datalink_send_pdu(&dest, &npdu_data, &buffer[0], pdu_len + len);
}

static void bp_send_segment_ack(
    const bp_transaction_t *tx,
    uint8_t invoke_id,
    bool negative,
    uint8_t sequence,
    uint8_t window)
{
    uint8_t apdu[4];
    int len = segmentack_encode_apdu(
        &apdu[0], negative, false, invoke_id, sequence, window);

    bp_send_apdu(tx, &apdu[0], len);
}

void bp_tx_end(bp_transaction_t *tx)
{
    if (tx->segments) {
        free(tx->segments->data);
        free(tx->segments);
        tx->segments = NULL;
        bp_state.segmenting--;
    }
    tx->active = false;
}

static void bp_segments_fail(
    bp_transaction_t *tx, uint8_t invoke_id, uint8_t kind, uint8_t reason)
{
    bp_event_header_t hdr;

    if (kind == BP_EVENT_ABORT) {
        uint8_t apdu[4];
        int len = abort_encode_apdu(&apdu[0], invoke_id, reason, false);
        bp_send_apdu(tx, &apdu[0], len);
    }
    bp_event_init(&hdr, kind);
    hdr.invoke_id = invoke_id;
    hdr.service = tx->service;
    hdr.device_id = tx->device_id;
    if (kind == BP_EVENT_ABORT) {
        hdr.flags = BP_FLAG_LOCAL;
        hdr.a = reason;
    } else {
        bp_state.stats.timeouts++;
    }
    bp_event_src(&hdr, &tx->dest);
    bp_event_push(&hdr, NULL, 0);
    bp_tx_end(tx);
    tsm_free_invoke_id(invoke_id);
}

static bool bp_segments_append(
    bp_segments_t *segments, const uint8_t *data, uint32_t length)
{
    uint32_t needed = segments->length + length;

    if (needed > BP_SEGMENTS_MAX_BYTES) {
        return false;
    }
    if (needed > segments->capacity) {
        uint32_t capacity = segments->capacity ? segments->capacity : 4096u;
        uint8_t *buffer;

        while (capacity < needed) {
            capacity *= 2;
        }
        buffer = (uint8_t *)realloc(segments->data, capacity);
        if (!buffer) {
            return false;
        }
        segments->data = buffer;
        segments->capacity = capacity;
    }
    if (length) {
        memcpy(&segments->data[segments->length], data, length);
    }
    segments->length = needed;
    return true;
}

static void bp_segments_complete(bp_transaction_t *tx, uint8_t invoke_id)
{
    bp_event_header_t hdr;

    bp_event_init(&hdr, BP_EVENT_COMPLEX_ACK);
    hdr.invoke_id = invoke_id;
    hdr.service = tx->service;
    hdr.device_id = tx->device_id;
    hdr.flags = BP_FLAG_SEGMENTED;
    bp_event_src(&hdr, &tx->dest);
    bp_event_push(&hdr, tx->segments->data, tx->segments->length);
    bp_state.stats.segmented_replies++;
    bp_tx_end(tx);
    tsm_free_invoke_id(invoke_id);
}

void bp_segment_received(
    const BACNET_ADDRESS *src, const uint8_t *apdu, uint16_t apdu_len)
{
    bp_transaction_t *tx;
    bp_segments_t *segments;
    uint8_t invoke_id;
    uint8_t sequence;
    uint8_t window;
    bool more_follows;
    uint32_t now;

    /* PDU type, invoke id, sequence number, window, service choice */
    if (apdu_len < 5) {
        return;
    }
    more_follows = (apdu[0] & 0x04) != 0;
    invoke_id = apdu[1];
    sequence = apdu[2];
    window = apdu[3];
    tx = bp_tx_for(invoke_id);
    if (!tx || apdu[4] != tx->service || !bacnet_address_same(&tx->dest, src)) {
        bp_state.stats.replies_dropped++;
        return;
    }
    if (bp_state.max_segments < 2) {
        bp_segments_fail(
            tx, invoke_id, BP_EVENT_ABORT,
            ABORT_REASON_SEGMENTATION_NOT_SUPPORTED);
        return;
    }
    now = (uint32_t)mstimer_now();
    segments = tx->segments;
    if (!segments) {
        /* first segment, answering our request */
        if (sequence != 0) {
            bp_segments_fail(
                tx, invoke_id, BP_EVENT_ABORT,
                ABORT_REASON_INVALID_APDU_IN_THIS_STATE);
            return;
        }
        segments = (bp_segments_t *)calloc(1, sizeof(*segments));
        if (!segments) {
            bp_segments_fail(
                tx, invoke_id, BP_EVENT_ABORT, ABORT_REASON_OUT_OF_RESOURCES);
            return;
        }
        tx->segments = segments;
        bp_state.segmenting++;
        bp_tsm_hold(invoke_id);
        segments->window = window == 0 ? 1 : (window > 127 ? 127 : window);
    } else if (sequence != (uint8_t)(segments->last + 1)) {
        /* lost or repeated segment: ask for the rest of the window again */
        bp_send_segment_ack(
            tx, invoke_id, true, segments->last, segments->window);
        segments->initial = segments->last;
        return;
    }
    if (!bp_segments_append(segments, &apdu[5], (uint32_t)apdu_len - 5u)) {
        bp_segments_fail(
            tx, invoke_id, BP_EVENT_ABORT, ABORT_REASON_BUFFER_OVERFLOW);
        return;
    }
    segments->last = sequence;
    segments->deadline = now + bp_segment_timeout();
    if (!more_follows) {
        bp_send_segment_ack(tx, invoke_id, false, sequence, segments->window);
        bp_segments_complete(tx, invoke_id);
    } else if (
        sequence == 0 ||
        sequence == (uint8_t)(segments->initial + segments->window)) {
        bp_send_segment_ack(tx, invoke_id, false, sequence, segments->window);
        segments->initial = sequence;
    }
}

void bp_segments_timer(uint32_t now)
{
    unsigned invoke_id;

    if (bp_state.segmenting == 0) {
        return;
    }
    for (invoke_id = 1; invoke_id < 256; invoke_id++) {
        bp_transaction_t *tx = &bp_state.tx[invoke_id];

        if (tx->active && tx->segments &&
            (int32_t)(now - tx->segments->deadline) >= 0) {
            bp_segments_fail(tx, (uint8_t)invoke_id, BP_EVENT_TIMEOUT, 0);
        }
    }
}
