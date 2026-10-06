/*
 * bacnet_plugin - engine lifecycle, timers and the receive path.
 *
 * See bacnet_plugin.h for the threading model and the event buffer format.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdlib.h>
#include <string.h>

#include "bacnet/apdu.h"
#include "bacnet/bacdcode.h"
#include "bacnet/basic/bbmd/h_bbmd.h"
#include "bacnet/basic/npdu/h_npdu.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/services.h"
#include "bacnet/basic/sys/mstimer.h"
#include "bacnet/basic/tsm/tsm.h"
#include "bacnet/datalink/bvlc.h"
#include "bacnet/datalink/datalink.h"
#if !defined(_WIN32) && defined(BACDL_BIP6)
#include "bacnet/datalink/bip6.h"
#endif
#include "bacnet/dcc.h"
#include "bacnet/npdu.h"
#include "bacnet/version.h"

#include "bp_internal.h"
#include "bp_object_table.h"
#include "bp_port.h"

/* Package version, passed by the build hook from pubspec.yaml. */
#ifndef BP_ENGINE_VERSION
#define BP_ENGINE_VERSION 0.0.0 - dev
#endif
#define BP_STRINGIFY(x) #x
#define BP_XSTRINGIFY(x) BP_STRINGIFY(x)

bp_state_t bp_state;

/* ---- timers ------------------------------------------------------------ */

static void bp_timers(void)
{
    uint32_t now = (uint32_t)mstimer_now();
    uint32_t elapsed = now - bp_state.last_ms;

    if (elapsed > 0) {
        bp_state.last_ms = now;
        tsm_timer_milliseconds((uint16_t)(elapsed > 0xFFFF ? 0xFFFF : elapsed));
        bp_state.second_acc += elapsed;
        if (bp_state.second_acc >= 1000) {
            uint32_t seconds = bp_state.second_acc / 1000;
            bp_state.second_acc %= 1000;
            datalink_maintenance_timer((uint16_t)seconds);
            dcc_timer_seconds(seconds);
            if (bp_state.server_enabled) {
                handler_cov_timer_seconds(seconds);
                bp_event_reporting(seconds);
                bp_backup_timer(seconds);
                bp_scm_task(seconds);
#if defined(INTRINSIC_REPORTING)
                bp_ee_task(seconds);
#endif
            }
            if (bp_state.fdr_ttl > 0) {
                uint32_t renew =
                    bp_state.fdr_ttl > 20 ? (uint32_t)bp_state.fdr_ttl / 2 : 10;
                bp_state.fdr_elapsed += seconds;
                if (bp_state.fdr_elapsed >= renew) {
                    bp_state.fdr_elapsed = 0;
                    (void)bvlc_register_with_bbmd(
                        &bp_state.fdr_bbmd, bp_state.fdr_ttl);
                }
            }
        }
        if (bp_state.server_enabled) {
            bp_state.object_acc += elapsed;
            if (bp_state.object_acc >= 100) {
                Device_Timer((uint16_t)(bp_state.object_acc > 0xFFFF
                                            ? 0xFFFF
                                            : bp_state.object_acc));
                bp_state.object_acc = 0;
            }
        }
    }
    bp_segments_timer(now);
    bp_cov_scan(now);
    bp_time_master_tick(now);
}

/* ---- receive path ------------------------------------------------------ */

static bool bp_accept_reply(BACNET_ADDRESS *src, uint8_t *pdu, uint16_t len)
{
    BACNET_ADDRESS dest;
    BACNET_ADDRESS full_src;
    BACNET_NPDU_DATA npdu_data;
    int offset;
    uint8_t type;
    bp_transaction_t *tx;

    if (len < 2 || pdu[0] != BACNET_PROTOCOL_VERSION) {
        return true;
    }
    bacnet_address_copy(&full_src, src);
    memset(&dest, 0, sizeof(dest));
    memset(&npdu_data, 0, sizeof(npdu_data));
    offset = bacnet_npdu_decode(pdu, len, &dest, &full_src, &npdu_data);
    if (offset > 0 && offset <= len && npdu_data.network_layer_message) {
        /* reported, then handled by the stack too (Network-Number-Is,
           I-Am-Router-To-Network of Notification Class recipients) */
        bp_network_received(
            &full_src, &dest, &npdu_data, &pdu[offset],
            (uint16_t)(len - offset));
        /* reply to router discovery when configured as a router */
        bp_router_on_network_message(
            src, &npdu_data, &pdu[offset], (uint16_t)(len - offset));
        return true;
    }
    if (offset <= 0 || offset + 2 > len) {
        return true;
    }
    type = pdu[offset] & 0xF0;
    if (type == PDU_TYPE_COMPLEX_ACK && (pdu[offset] & 0x08)) {
        /* segmented: bacnet-stack cannot reassemble it */
        bp_segment_received(&full_src, &pdu[offset], (uint16_t)(len - offset));
        return false;
    }
    if (!bp_state.strict_source) {
        return true;
    }
    switch (type) {
        case PDU_TYPE_SIMPLE_ACK:
        case PDU_TYPE_COMPLEX_ACK:
        case PDU_TYPE_ERROR:
        case PDU_TYPE_REJECT:
            break;
        case PDU_TYPE_ABORT:
            if ((pdu[offset] & 0x01) == 0) {
                return true;
            }
            break;
        default:
            return true;
    }
    tx = bp_tx_for(pdu[offset + 1]);
    if (tx && tx->segments && !bacnet_address_same(&tx->dest, &full_src)) {
        /* the invoke id is held for the segments of our transaction */
        bp_state.stats.replies_dropped++;
        return false;
    }
    if (tx && !bacnet_address_same(&tx->dest, &full_src)) {
        BACNET_ADDRESS tsm_dest;
        BACNET_NPDU_DATA tsm_npdu;
        uint16_t tsm_len = 0;

        if (!tsm_get_transaction_pdu(
                pdu[offset + 1], &tsm_dest, &tsm_npdu, &bp_state.tx_buf[0],
                &tsm_len) ||
            !bacnet_address_same(&tsm_dest, &tx->dest)) {
            /* our transaction ended without notice: the invoke id now
               belongs to another transaction of the stack */
            bp_tx_end(tx);
            return true;
        }
        /* reply for a recycled invoke id from another device: dropping it
           prevents completing a request with foreign data */
        bp_state.stats.replies_dropped++;
        return false;
    }
    return true;
}

BP_API int32_t bacnet_plugin_poll(uint32_t timeout_ms, uint32_t max_packets)
{
    int32_t processed = 0;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    bp_state.stats.poll_calls++;
    bp_timers();
    if (timeout_ms > 0) {
        bp_wait(timeout_ms);
    }
    bp_wake_drain();
    while ((uint32_t)processed < max_packets) {
        BACNET_ADDRESS src;
        uint16_t len;

        memset(&src, 0, sizeof(src));
        len = datalink_receive(&src, bp_state.rx_buf, MAX_MPDU, 0);
        if (len == 0) {
            break;
        }
        processed++;
        bp_receive_packet(&src, bp_state.rx_buf, len);
    }
    bp_timers();
    return processed;
}

void bp_receive_packet(BACNET_ADDRESS *src, uint8_t *pdu, uint16_t len)
{
    bp_state.stats.packets_received++;
    if (bp_accept_reply(src, pdu, len)) {
        bp_audit_set_source(src);
        npdu_handler(src, pdu, len);
        bp_audit_set_source(NULL);
    }
}

/* ---- lifecycle --------------------------------------------------------- */

BP_API const char *bacnet_plugin_version(void)
{
    return "bacnet_plugin/" BP_XSTRINGIFY(
        BP_ENGINE_VERSION) " bacnet-stack/" BACNET_VERSION_TEXT;
}

BP_API int32_t bacnet_plugin_set_ipv6(int32_t enabled)
{
    if (bp_state.initialized) {
        return BP_ERR_ALREADY_INITIALIZED;
    }
#if !defined(_WIN32) && defined(BACDL_BIP6)
    bp_state.ipv6 = enabled != 0;
    return BP_OK;
#else
    if (enabled) {
        return BP_ERR_UNSUPPORTED;
    }
    return BP_OK;
#endif
}

BP_API int32_t bacnet_plugin_init(
    const char *iface,
    uint16_t port,
    uint32_t device_instance,
    int32_t socket_buffer_bytes)
{
    if (bp_state.initialized) {
        return BP_ERR_ALREADY_INITIALIZED;
    }
    memset(&bp_state.stats, 0, sizeof(bp_state.stats));
    memset(bp_state.tx, 0, sizeof(bp_state.tx));
    bp_state.segmenting = 0;
    bp_state.max_segments = BP_DEFAULT_MAX_SEGMENTS;
    bp_state.server_enabled = false;
    bp_state.strict_source = true;
    bp_state.suppress_write_events = false;
    if (bp_state.cov_scan_interval_ms == 0) {
        bp_state.cov_scan_interval_ms = 50;
    }
    if (bp_state.cov_scan_budget == 0) {
        bp_state.cov_scan_budget = 1u << 20;
    }
    if (bp_state.ev_max == 0) {
        bp_state.ev_max = 64u * 1024u * 1024u;
    }
    bp_state.ev_len = 0;
    bp_state.socket_buffer_size =
        socket_buffer_bytes > 0 ? socket_buffer_bytes : 0;
#if !defined(_WIN32)
    bp_port_set_socket_buffer_size(bp_state.socket_buffer_size);
#endif

    mstimer_init();
    datetime_init();
    /* application objects only: no demo instances of the default table */
    Device_Init(BP_Object_Table);
    /* after Device_Init(), which links the objects to Device_Write_Property */
    bp_internal_writes_init();
    bp_state.internal_write = false;
    bp_backup_reset();
    if (device_instance <= BACNET_MAX_INSTANCE) {
        (void)Device_Set_Object_Instance_Number(device_instance);
    }
    address_init();
    address_own_device_id_set(Device_Object_Instance_Number());
    bp_register_client_handlers();

#if !defined(_WIN32) && defined(BACDL_BIP6)
    if (bp_state.ipv6) {
#if defined(BACDL_MULTIPLE)
        datalink_set("bip6");
#endif
        bip6_set_port(port ? port : 0xBAC0);
        if (!bip6_init(iface && *iface ? iface : NULL)) {
            return BP_ERR_DATALINK;
        }
    } else
#endif
    {
#if defined(BACDL_MULTIPLE)
        /* with a single compile-time datalink the macros already resolve to
           bip_*; datalink_set() exists only in the runtime-dispatch build */
        datalink_set("bip");
#endif
        bip_set_port(port ? port : 0xBAC0);
        if (!bip_init(iface && *iface ? iface : NULL)) {
            return BP_ERR_DATALINK;
        }
    }
#if defined(_WIN32)
    bp_apply_socket_buffer(bip_get_socket());
    bp_apply_socket_buffer(bip_get_broadcast_socket());
#endif
    if (!bp_wake_init()) {
        bip_cleanup();
        return BP_ERR_DATALINK;
    }
    bp_wake_drain();
    bp_state.last_ms = (uint32_t)mstimer_now();
    bp_state.cov_scan_last = bp_state.last_ms;
    bp_state.second_acc = 0;
    bp_state.object_acc = 0;
    bp_state.fdr_ttl = 0;
    bp_state.initialized = true;
    return BP_OK;
}

BP_API void bacnet_plugin_shutdown(void)
{
    unsigned invoke_id;

    if (!bp_state.initialized) {
        return;
    }
    for (invoke_id = 1; invoke_id < 256; invoke_id++) {
        if (bp_state.tx[invoke_id].active) {
            bp_tx_end(&bp_state.tx[invoke_id]);
            tsm_free_invoke_id((uint8_t)invoke_id);
        }
    }
    memset(bp_state.tx, 0, sizeof(bp_state.tx));
    Device_Write_Property_Store_Callback_Set(NULL);
    if (bp_state.server_enabled) {
        Device_Delete_Objects();
    }
    bip_cleanup();
    free(bp_state.devices.entries);
    memset(&bp_state.devices, 0, sizeof(bp_state.devices));
    bp_string_clear();
    free(bp_state.ev_buf);
    bp_state.ev_buf = NULL;
    bp_state.ev_len = 0;
    bp_state.ev_cap = 0;
    bp_state.server_enabled = false;
    bp_state.fdr_ttl = 0;
    bp_state.initialized = false;
}

BP_API int32_t bacnet_plugin_set_option(int32_t option, int64_t value)
{
    switch (option) {
        case BP_OPTION_STRICT_SOURCE:
            bp_state.strict_source = value != 0;
            return BP_OK;
        case BP_OPTION_COV_SCAN_INTERVAL_MS:
            if (value < 1 || value > 60000) {
                return BP_ERR_INVALID_ARGUMENT;
            }
            bp_state.cov_scan_interval_ms = (uint32_t)value;
            return BP_OK;
        case BP_OPTION_MAX_EVENT_BUFFER:
            if (value < 64 * 1024 || value > 0x7FFFFFFF) {
                return BP_ERR_INVALID_ARGUMENT;
            }
            bp_state.ev_max = (uint32_t)value;
            return BP_OK;
        case BP_OPTION_APDU_TIMEOUT_MS:
            if (value < 100 || value > 0xFFFF) {
                return BP_ERR_INVALID_ARGUMENT;
            }
            apdu_timeout_set((uint16_t)value);
            return BP_OK;
        case BP_OPTION_APDU_RETRIES:
            if (value < 0 || value > 10) {
                return BP_ERR_INVALID_ARGUMENT;
            }
            apdu_retries_set((uint8_t)value);
            return BP_OK;
        case BP_OPTION_COV_SCAN_BUDGET:
            if (value < 1) {
                return BP_ERR_INVALID_ARGUMENT;
            }
            bp_state.cov_scan_budget = (uint32_t)value;
            return BP_OK;
        case BP_OPTION_MAX_SEGMENTS:
            if (value < 0 || value > 32) {
                return BP_ERR_INVALID_ARGUMENT;
            }
            bp_state.max_segments = (uint8_t)value;
            return BP_OK;
        default:
            return BP_ERR_INVALID_ARGUMENT;
    }
}

BP_API void bacnet_plugin_stats(bp_stats_t *out)
{
    if (!out) {
        return;
    }
    *out = bp_state.stats;
    out->tsm_idle = bp_state.initialized ? tsm_transaction_idle_count() : 0;
    out->bound_devices = bp_state.devices.used;
    out->event_buffer_capacity = bp_state.ev_cap;
}
