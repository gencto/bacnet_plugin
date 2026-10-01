/*
 * bacnet_plugin - client side: confirmed and unconfirmed requests,
 * replies, address bindings and foreign device registration.
 *
 * SPDX-License-Identifier: MIT
 */
#include <string.h>

#include "bacnet/abort.h"
#include "bacnet/apdu.h"
#include "bacnet/bacdcode.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/services.h"
#include "bacnet/basic/tsm/tsm.h"
#include "bacnet/datalink/bvlc.h"
#include "bacnet/dcc.h"
#include "bacnet/iam.h"
#include "bacnet/npdu.h"
#include "bacnet/reject.h"

#include "bp_internal.h"

bp_transaction_t *bp_tx_for(uint8_t invoke_id)
{
    bp_transaction_t *tx = &bp_state.tx[invoke_id];

    return tx->active ? tx : NULL;
}

static void bp_tx_event(
    bp_transaction_t *tx, uint8_t kind, uint8_t invoke_id, BACNET_ADDRESS *src)
{
    bp_event_header_t hdr;

    bp_event_init(&hdr, kind);
    hdr.invoke_id = invoke_id;
    hdr.service = tx->service;
    hdr.device_id = tx->device_id;
    bp_event_src(&hdr, src);
    bp_event_push(&hdr, NULL, 0);
}

static void bp_on_complex_ack(
    uint8_t *service_request,
    uint16_t service_len,
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_ACK_DATA *service_data)
{
    bp_transaction_t *tx = bp_tx_for(service_data->invoke_id);
    bp_event_header_t hdr;

    if (!tx) {
        return;
    }
    bp_event_init(&hdr, BP_EVENT_COMPLEX_ACK);
    hdr.invoke_id = service_data->invoke_id;
    hdr.service = tx->service;
    hdr.device_id = tx->device_id;
    bp_event_src(&hdr, src);
    if (service_data->segmented_message) {
        /* segmentation is not supported: abort the transfer */
        BACNET_NPDU_DATA npdu_data;
        BACNET_ADDRESS my_address;
        int len;

        hdr.kind = BP_EVENT_ABORT;
        hdr.flags = BP_FLAG_LOCAL;
        hdr.a = ABORT_REASON_SEGMENTATION_NOT_SUPPORTED;
        bp_event_push(&hdr, NULL, 0);
        datalink_get_my_address(&my_address);
        npdu_encode_npdu_data(&npdu_data, false, MESSAGE_PRIORITY_NORMAL);
        len =
            npdu_encode_pdu(&bp_state.tx_buf[0], src, &my_address, &npdu_data);
        len += abort_encode_apdu(
            &bp_state.tx_buf[len], service_data->invoke_id,
            ABORT_REASON_SEGMENTATION_NOT_SUPPORTED, false);
        (void)datalink_send_pdu(src, &npdu_data, &bp_state.tx_buf[0], len);
    } else {
        bp_event_push(&hdr, service_request, service_len);
    }
    bp_tx_end(tx);
}

static void bp_on_simple_ack(BACNET_ADDRESS *src, uint8_t invoke_id)
{
    bp_transaction_t *tx = bp_tx_for(invoke_id);

    if (tx) {
        bp_tx_event(tx, BP_EVENT_SIMPLE_ACK, invoke_id, src);
        bp_tx_end(tx);
    }
}

static void bp_on_error(
    BACNET_ADDRESS *src,
    uint8_t invoke_id,
    BACNET_ERROR_CLASS error_class,
    BACNET_ERROR_CODE error_code)
{
    bp_transaction_t *tx = bp_tx_for(invoke_id);
    bp_event_header_t hdr;

    if (!tx) {
        return;
    }
    bp_event_init(&hdr, BP_EVENT_ERROR);
    hdr.invoke_id = invoke_id;
    hdr.service = tx->service;
    hdr.device_id = tx->device_id;
    hdr.a = (uint32_t)error_class;
    hdr.b = (uint32_t)error_code;
    bp_event_src(&hdr, src);
    bp_event_push(&hdr, NULL, 0);
    bp_tx_end(tx);
}

static void bp_on_complex_error(
    BACNET_ADDRESS *src,
    uint8_t invoke_id,
    uint8_t service_choice,
    uint8_t *service_request,
    uint16_t service_len)
{
    bp_transaction_t *tx = bp_tx_for(invoke_id);
    bp_event_header_t hdr;

    (void)service_choice;
    if (!tx) {
        return;
    }
    bp_event_init(&hdr, BP_EVENT_ERROR);
    hdr.invoke_id = invoke_id;
    hdr.service = tx->service;
    hdr.device_id = tx->device_id;
    hdr.flags = BP_FLAG_COMPLEX;
    hdr.a = 0xFFFFFFFFu;
    hdr.b = 0xFFFFFFFFu;
    bp_event_src(&hdr, src);
    bp_event_push(&hdr, service_request, service_len);
    bp_tx_end(tx);
}

static void bp_on_abort(
    BACNET_ADDRESS *src, uint8_t invoke_id, uint8_t abort_reason, bool server)
{
    bp_transaction_t *tx;
    bp_event_header_t hdr;

    if (!server) {
        return;
    }
    tx = bp_tx_for(invoke_id);
    if (!tx) {
        return;
    }
    bp_event_init(&hdr, BP_EVENT_ABORT);
    hdr.invoke_id = invoke_id;
    hdr.service = tx->service;
    hdr.device_id = tx->device_id;
    hdr.flags = BP_FLAG_ABORT_FROM_SERVER;
    hdr.a = abort_reason;
    bp_event_src(&hdr, src);
    bp_event_push(&hdr, NULL, 0);
    bp_tx_end(tx);
}

static void
bp_on_reject(BACNET_ADDRESS *src, uint8_t invoke_id, uint8_t reject_reason)
{
    bp_transaction_t *tx = bp_tx_for(invoke_id);
    bp_event_header_t hdr;

    if (!tx) {
        return;
    }
    bp_event_init(&hdr, BP_EVENT_REJECT);
    hdr.invoke_id = invoke_id;
    hdr.service = tx->service;
    hdr.device_id = tx->device_id;
    hdr.a = reject_reason;
    bp_event_src(&hdr, src);
    bp_event_push(&hdr, NULL, 0);
    bp_tx_end(tx);
}

static void bp_on_timeout(uint8_t invoke_id)
{
    bp_transaction_t *tx = bp_tx_for(invoke_id);

    if (!tx) {
        /* not ours (e.g. a confirmed COV notification of the server):
           the owner frees the invoke id */
        return;
    }
    bp_tx_event(tx, BP_EVENT_TIMEOUT, invoke_id, &tx->dest);
    bp_tx_end(tx);
    bp_state.stats.timeouts++;
    /* a failed transaction keeps its TSM slot until freed */
    tsm_free_invoke_id(invoke_id);
}

static void
bp_on_i_am(uint8_t *service_request, uint16_t service_len, BACNET_ADDRESS *src)
{
    uint32_t device_id = 0;
    unsigned max_apdu = 0;
    int segmentation = 0;
    uint16_t vendor_id = 0;
    bp_event_header_t hdr;
    bp_device_entry_t *entry;
    int len;

    len = bacnet_iam_request_decode(
        service_request, service_len, &device_id, &max_apdu, &segmentation,
        &vendor_id);
    if (len <= 0) {
        return;
    }
    if (bp_state.server_enabled &&
        device_id == Device_Object_Instance_Number()) {
        return;
    }
    if (max_apdu > MAX_APDU) {
        max_apdu = MAX_APDU;
    }
    entry = bp_device_put(device_id, src, (uint16_t)max_apdu);
    if (entry) {
        entry->vendor_id = vendor_id;
        entry->segmentation = (uint8_t)segmentation;
    }
    bp_event_init(&hdr, BP_EVENT_UNCONFIRMED);
    hdr.service = SERVICE_UNCONFIRMED_I_AM;
    hdr.device_id = device_id;
    hdr.a = max_apdu;
    hdr.b = vendor_id;
    hdr.c = (uint32_t)segmentation;
    bp_event_src(&hdr, src);
    bp_event_push(&hdr, service_request, service_len);
}

static void bp_forward_unconfirmed(
    uint8_t service,
    uint8_t *service_request,
    uint16_t service_len,
    BACNET_ADDRESS *src)
{
    bp_event_header_t hdr;

    bp_event_init(&hdr, BP_EVENT_UNCONFIRMED);
    hdr.service = service;
    bp_event_src(&hdr, src);
    bp_event_push(&hdr, service_request, service_len);
}

#define BP_UNCONFIRMED_FORWARDER(name, service)                           \
    static void name(uint8_t *request, uint16_t len, BACNET_ADDRESS *src) \
    {                                                                     \
        bp_forward_unconfirmed((service), request, len, src);             \
    }

BP_UNCONFIRMED_FORWARDER(bp_on_ucov, SERVICE_UNCONFIRMED_COV_NOTIFICATION)
BP_UNCONFIRMED_FORWARDER(bp_on_i_have, SERVICE_UNCONFIRMED_I_HAVE)
BP_UNCONFIRMED_FORWARDER(bp_on_uevent, SERVICE_UNCONFIRMED_EVENT_NOTIFICATION)
BP_UNCONFIRMED_FORWARDER(bp_on_utext, SERVICE_UNCONFIRMED_TEXT_MESSAGE)
BP_UNCONFIRMED_FORWARDER(bp_on_uprivate, SERVICE_UNCONFIRMED_PRIVATE_TRANSFER)

static void bp_confirmed_notification(
    uint8_t service,
    uint8_t *service_request,
    uint16_t service_len,
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_DATA *service_data)
{
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    bp_event_header_t hdr;
    int len;

    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(&npdu_data, false, service_data->priority);
    len = npdu_encode_pdu(&bp_state.tx_buf[0], src, &my_address, &npdu_data);
    if (service_data->segmented_message) {
        len += abort_encode_apdu(
            &bp_state.tx_buf[len], service_data->invoke_id,
            ABORT_REASON_SEGMENTATION_NOT_SUPPORTED, true);
    } else if (service_len == 0) {
        len += reject_encode_apdu(
            &bp_state.tx_buf[len], service_data->invoke_id,
            REJECT_REASON_MISSING_REQUIRED_PARAMETER);
    } else {
        len += encode_simple_ack(
            &bp_state.tx_buf[len], service_data->invoke_id, service);
        bp_event_init(&hdr, BP_EVENT_CONFIRMED_NOTIFICATION);
        hdr.service = service;
        hdr.invoke_id = service_data->invoke_id;
        bp_event_src(&hdr, src);
        bp_event_push(&hdr, service_request, service_len);
    }
    (void)datalink_send_pdu(src, &npdu_data, &bp_state.tx_buf[0], len);
}

static void bp_on_ccov(
    uint8_t *service_request,
    uint16_t service_len,
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_DATA *service_data)
{
    bp_confirmed_notification(
        SERVICE_CONFIRMED_COV_NOTIFICATION, service_request, service_len, src,
        service_data);
}

static void bp_on_cevent(
    uint8_t *service_request,
    uint16_t service_len,
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_DATA *service_data)
{
    bp_confirmed_notification(
        SERVICE_CONFIRMED_EVENT_NOTIFICATION, service_request, service_len, src,
        service_data);
}

void bp_register_client_handlers(void)
{
    int service;

    for (service = 0; service < MAX_BACNET_CONFIRMED_SERVICE; service++) {
        if (apdu_confirmed_simple_ack_service(
                (BACNET_CONFIRMED_SERVICE)service)) {
            apdu_set_confirmed_simple_ack_handler(
                (BACNET_CONFIRMED_SERVICE)service, bp_on_simple_ack);
        } else {
            apdu_set_confirmed_ack_handler(
                (BACNET_CONFIRMED_SERVICE)service, bp_on_complex_ack);
        }
        if (apdu_complex_error((uint8_t)service)) {
            apdu_set_complex_error_handler(
                (BACNET_CONFIRMED_SERVICE)service, bp_on_complex_error);
        } else {
            apdu_set_error_handler(
                (BACNET_CONFIRMED_SERVICE)service, bp_on_error);
        }
    }
    apdu_set_abort_handler(bp_on_abort);
    apdu_set_reject_handler(bp_on_reject);
    tsm_set_timeout_handler(bp_on_timeout);
    apdu_set_unrecognized_service_handler_handler(handler_unrecognized_service);
    apdu_set_unconfirmed_handler(SERVICE_UNCONFIRMED_I_AM, bp_on_i_am);
    apdu_set_unconfirmed_handler(
        SERVICE_UNCONFIRMED_COV_NOTIFICATION, bp_on_ucov);
    apdu_set_unconfirmed_handler(SERVICE_UNCONFIRMED_I_HAVE, bp_on_i_have);
    apdu_set_unconfirmed_handler(
        SERVICE_UNCONFIRMED_EVENT_NOTIFICATION, bp_on_uevent);
    apdu_set_unconfirmed_handler(SERVICE_UNCONFIRMED_TEXT_MESSAGE, bp_on_utext);
    apdu_set_unconfirmed_handler(
        SERVICE_UNCONFIRMED_PRIVATE_TRANSFER, bp_on_uprivate);
    apdu_set_confirmed_handler(SERVICE_CONFIRMED_COV_NOTIFICATION, bp_on_ccov);
    apdu_set_confirmed_handler(
        SERVICE_CONFIRMED_EVENT_NOTIFICATION, bp_on_cevent);
}

BP_API int32_t bacnet_plugin_send_confirmed(
    uint32_t device_id,
    uint8_t service,
    const uint8_t *data,
    uint16_t data_len,
    uint8_t priority)
{
    bp_device_entry_t *device;
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    BACNET_ADDRESS dest;
    uint8_t invoke_id;
    int pdu_len;
    int apdu_len;
    int sent;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (data_len > 0 && !data) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    device = bp_device_find(device_id);
    if (!device) {
        return BP_ERR_NOT_BOUND;
    }
    if (!dcc_communication_enabled()) {
        return BP_ERR_COMMUNICATION_DISABLED;
    }
    apdu_len = 4 + data_len;
    if (apdu_len > device->max_apdu || apdu_len > MAX_APDU) {
        return BP_ERR_APDU_TOO_LARGE;
    }
    invoke_id = tsm_next_free_invokeID();
    if (invoke_id == 0) {
        return BP_ERR_NO_TRANSACTION;
    }
    bacnet_address_copy(&dest, &device->address);
    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(
        &npdu_data, true,
        priority <= MESSAGE_PRIORITY_LIFE_SAFETY
            ? (BACNET_MESSAGE_PRIORITY)priority
            : MESSAGE_PRIORITY_NORMAL);
    pdu_len =
        npdu_encode_pdu(&bp_state.tx_buf[0], &dest, &my_address, &npdu_data);
    if (pdu_len <= 0 || pdu_len + apdu_len > (int)sizeof(bp_state.tx_buf)) {
        tsm_free_invoke_id(invoke_id);
        return BP_ERR_APDU_TOO_LARGE;
    }
    /* segmented answers are reassembled by bp_segments.c */
    bp_state.tx_buf[pdu_len] = PDU_TYPE_CONFIRMED_SERVICE_REQUEST |
        (bp_state.max_segments > 1 ? 0x02 : 0x00);
    bp_state.tx_buf[pdu_len + 1] =
        encode_max_segs_max_apdu(bp_state.max_segments, MAX_APDU);
    bp_state.tx_buf[pdu_len + 2] = invoke_id;
    bp_state.tx_buf[pdu_len + 3] = service;
    if (data_len) {
        memcpy(&bp_state.tx_buf[pdu_len + 4], data, data_len);
    }
    pdu_len += apdu_len;
    tsm_set_confirmed_unsegmented_transaction(
        invoke_id, &dest, &npdu_data, &bp_state.tx_buf[0], (uint16_t)pdu_len);
    bp_state.last_invoke_id = invoke_id;
    if (bp_state.tx[invoke_id].active) {
        /* the stack recycled the invoke id: release what is left of it */
        bp_tx_end(&bp_state.tx[invoke_id]);
    }
    bp_state.tx[invoke_id].active = true;
    bp_state.tx[invoke_id].service = service;
    bp_state.tx[invoke_id].device_id = device_id;
    bacnet_address_copy(&bp_state.tx[invoke_id].dest, &dest);
    sent = datalink_send_pdu(&dest, &npdu_data, &bp_state.tx_buf[0], pdu_len);
    bp_state.stats.requests_sent++;
    if (sent <= 0) {
        /* keep the transaction: the TSM retries the transmission */
        bp_log(2, "send to device %u failed, will retry", device_id);
    }
    return invoke_id;
}

BP_API int32_t bacnet_plugin_send_unconfirmed(
    uint32_t device_id,
    uint16_t network,
    uint8_t service,
    const uint8_t *data,
    uint16_t data_len)
{
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    BACNET_ADDRESS dest;
    int pdu_len;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (data_len > 0 && !data) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    if (!dcc_communication_enabled()) {
        return BP_ERR_COMMUNICATION_DISABLED;
    }
    if (device_id == BP_DEVICE_UNKNOWN) {
        datalink_get_broadcast_address(&dest);
        dest.net = network;
    } else {
        bp_device_entry_t *device = bp_device_find(device_id);
        if (!device) {
            return BP_ERR_NOT_BOUND;
        }
        bacnet_address_copy(&dest, &device->address);
    }
    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(&npdu_data, false, MESSAGE_PRIORITY_NORMAL);
    pdu_len =
        npdu_encode_pdu(&bp_state.tx_buf[0], &dest, &my_address, &npdu_data);
    if (pdu_len <= 0 || pdu_len + 2 + data_len > MAX_PDU ||
        2 + data_len > MAX_APDU) {
        return BP_ERR_APDU_TOO_LARGE;
    }
    bp_state.tx_buf[pdu_len++] = PDU_TYPE_UNCONFIRMED_SERVICE_REQUEST;
    bp_state.tx_buf[pdu_len++] = service;
    if (data_len) {
        memcpy(&bp_state.tx_buf[pdu_len], data, data_len);
        pdu_len += data_len;
    }
    bp_state.stats.requests_sent++;
    if (datalink_send_pdu(&dest, &npdu_data, &bp_state.tx_buf[0], pdu_len) <=
        0) {
        return BP_ERR_SEND_FAILED;
    }
    return BP_OK;
}

static bool bp_resolve_ipv4(const char *host, uint8_t out[4])
{
    BACNET_IP_ADDRESS address;

    if (!host || !*host) {
        return false;
    }
    memset(&address, 0, sizeof(address));
    if (!bip_get_addr_by_name(host, &address)) {
        return false;
    }
    memcpy(out, address.address, 4);
    return true;
}

BP_API int32_t bacnet_plugin_bind_device(
    uint32_t device_id,
    const char *host,
    uint16_t port,
    uint16_t net,
    const uint8_t *adr,
    uint8_t adr_len,
    uint16_t max_apdu)
{
    BACNET_ADDRESS address;
    uint8_t ip[4];

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (device_id > BACNET_MAX_INSTANCE || adr_len > MAX_MAC_LEN ||
        (adr_len > 0 && !adr)) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    if (!bp_resolve_ipv4(host, ip)) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    memset(&address, 0, sizeof(address));
    address.mac_len = 6;
    memcpy(&address.mac[0], ip, 4);
    address.mac[4] = (uint8_t)(port >> 8);
    address.mac[5] = (uint8_t)(port & 0xFF);
    address.net = net;
    address.len = adr_len;
    if (adr_len) {
        memcpy(address.adr, adr, adr_len);
    }
    if (max_apdu == 0 || max_apdu > MAX_APDU) {
        max_apdu = MAX_APDU;
    }
    return bp_device_put(device_id, &address, max_apdu) ? BP_OK
                                                        : BP_ERR_NO_MEMORY;
}

BP_API void bacnet_plugin_unbind_device(uint32_t device_id)
{
    bp_device_remove(device_id);
}

BP_API int32_t bacnet_plugin_device_binding(
    uint32_t device_id,
    uint8_t *mac,
    uint8_t *mac_len,
    uint16_t *net,
    uint16_t *max_apdu)
{
    bp_device_entry_t *device = bp_device_find(device_id);

    if (!device) {
        return 0;
    }
    if (mac) {
        memcpy(mac, device->address.mac, 7);
    }
    if (mac_len) {
        *mac_len = device->address.mac_len;
    }
    if (net) {
        *net = device->address.net;
    }
    if (max_apdu) {
        *max_apdu = device->max_apdu;
    }
    return 1;
}

BP_API int32_t bacnet_plugin_register_foreign_device(
    const char *host, uint16_t port, uint16_t ttl_seconds)
{
    BACNET_IP_ADDRESS bbmd;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    memset(&bbmd, 0, sizeof(bbmd));
    if (!bp_resolve_ipv4(host, bbmd.address) || ttl_seconds == 0) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    bbmd.port = port ? port : 0xBAC0;
    if (bvlc_register_with_bbmd(&bbmd, ttl_seconds) <= 0) {
        return BP_ERR_SEND_FAILED;
    }
    bp_state.fdr_bbmd = bbmd;
    bp_state.fdr_ttl = ttl_seconds;
    bp_state.fdr_elapsed = 0;
    return BP_OK;
}
