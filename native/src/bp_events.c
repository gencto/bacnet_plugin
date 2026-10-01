/*
 * bacnet_plugin - event buffer drained by Dart after each poll.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bp_internal.h"

typedef char
    bp_event_header_size_check[(sizeof(bp_event_header_t) == 48) ? 1 : -1];

static bool bp_event_reserve(uint32_t needed)
{
    uint32_t capacity;
    uint8_t *buffer;

    if (bp_state.ev_len + needed <= bp_state.ev_cap) {
        return true;
    }
    if (bp_state.ev_len + needed > bp_state.ev_max) {
        return false;
    }
    capacity = bp_state.ev_cap ? bp_state.ev_cap : 64u * 1024u;
    while (capacity < bp_state.ev_len + needed) {
        capacity *= 2;
    }
    if (capacity > bp_state.ev_max) {
        capacity = bp_state.ev_max;
    }
    buffer = (uint8_t *)realloc(bp_state.ev_buf, capacity);
    if (!buffer) {
        return false;
    }
    bp_state.ev_buf = buffer;
    bp_state.ev_cap = capacity;
    return true;
}

void bp_event_src(bp_event_header_t *hdr, const BACNET_ADDRESS *src)
{
    if (!src) {
        return;
    }
    hdr->src_mac_len = src->mac_len > 7 ? 7 : src->mac_len;
    memcpy(hdr->src_mac, src->mac, hdr->src_mac_len);
    hdr->src_net = src->net;
    hdr->src_len = src->len > 7 ? 7 : src->len;
    memcpy(hdr->src_adr, src->adr, hdr->src_len);
}

void bp_event_push(
    bp_event_header_t *hdr, const uint8_t *data, uint32_t data_len)
{
    uint32_t needed;

    if (data_len > 0xFFFFu) {
        data_len = 0xFFFFu;
    }
    hdr->data_len = (uint16_t)data_len;
    needed = (uint32_t)sizeof(*hdr) + data_len;
    if (!bp_event_reserve(needed)) {
        bp_state.stats.events_dropped++;
        return;
    }
    memcpy(&bp_state.ev_buf[bp_state.ev_len], hdr, sizeof(*hdr));
    if (data_len && data) {
        memcpy(
            &bp_state.ev_buf[bp_state.ev_len + sizeof(*hdr)], data, data_len);
    }
    bp_state.ev_len += needed;
}

void bp_event_init(bp_event_header_t *hdr, uint8_t kind)
{
    memset(hdr, 0, sizeof(*hdr));
    hdr->kind = kind;
    hdr->device_id = BP_DEVICE_UNKNOWN;
    hdr->d = -1;
}

void bp_log(int level, const char *format, ...)
{
    bp_event_header_t hdr;
    char text[256];
    va_list args;
    int len;

    va_start(args, format);
    len = vsnprintf(text, sizeof(text), format, args);
    va_end(args);
    if (len < 0) {
        return;
    }
    if (len >= (int)sizeof(text)) {
        len = (int)sizeof(text) - 1;
    }
    bp_event_init(&hdr, BP_EVENT_LOG);
    hdr.a = (uint32_t)level;
    bp_event_push(&hdr, (const uint8_t *)text, (uint32_t)len);
}

BP_API const uint8_t *bacnet_plugin_events_data(void)
{
    return bp_state.ev_buf;
}

BP_API uint32_t bacnet_plugin_events_length(void)
{
    return bp_state.ev_len;
}

BP_API void bacnet_plugin_events_clear(void)
{
    bp_state.ev_len = 0;
}
