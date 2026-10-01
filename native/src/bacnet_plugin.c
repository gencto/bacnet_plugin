/*
 * bacnet_plugin - native engine around bacnet-stack.
 *
 * See bacnet_plugin.h for the threading model and the event buffer format.
 *
 * SPDX-License-Identifier: MIT
 */
#if defined(_WIN32)
#include "bacport.h" /* winsock2 before windows.h */
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#endif

#include <math.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bacnet/abort.h"
#include "bacnet/apdu.h"
#include "bacnet/bacaddr.h"
#include "bacnet/bacdcode.h"
#include "bacnet/bacdef.h"
#include "bacnet/bacenum.h"
#include "bacnet/bacstr.h"
#include "bacnet/basic/bbmd/h_bbmd.h"
#include "bacnet/basic/npdu/h_npdu.h"
#include "bacnet/basic/object/ai.h"
#include "bacnet/basic/object/ao.h"
#include "bacnet/basic/object/av.h"
#include "bacnet/basic/object/bi.h"
#include "bacnet/basic/object/bo.h"
#include "bacnet/basic/object/bv.h"
#include "bacnet/basic/object/csv.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/object/iv.h"
#include "bacnet/basic/object/ms-input.h"
#include "bacnet/basic/object/mso.h"
#include "bacnet/basic/object/msv.h"
#include "bacnet/basic/object/piv.h"
#include "bacnet/basic/object/trendlog.h"
#include "bacnet/basic/services.h"
#include "bacnet/basic/sys/mstimer.h"
#include "bacnet/basic/tsm/tsm.h"
#include "bacnet/datalink/bip.h"
#include "bacnet/datalink/bvlc.h"
#include "bacnet/datalink/datalink.h"
#include "bacnet/dcc.h"
#include "bacnet/iam.h"
#include "bacnet/npdu.h"
#include "bacnet/reject.h"
#include "bacnet/version.h"

#include "bacnet_plugin.h"
#include "bp_object_table.h"
#include "bp_port.h"

#define BP_ENGINE_VERSION "0.1.0"

typedef char bp_event_header_size_check
    [(sizeof(bp_event_header_t) == 48) ? 1 : -1];

/* ---- platform helpers ------------------------------------------------- */

#if defined(_WIN32)
typedef SOCKET bp_socket_t;
#define BP_INVALID_SOCKET INVALID_SOCKET
#define bp_close_socket closesocket
typedef volatile LONG bp_atomic_t;
#define bp_atomic_exchange(p, v) InterlockedExchange((p), (v))
#else
typedef int bp_socket_t;
#define BP_INVALID_SOCKET (-1)
#define bp_close_socket close
typedef volatile int bp_atomic_t;
#define bp_atomic_exchange(p, v) __atomic_exchange_n((p), (v), __ATOMIC_ACQ_REL)
#endif

/* ---- device address table (open addressing hash map) ----------------- */

typedef struct {
    uint32_t device_id;
    uint8_t state; /* 0 empty, 1 used, 2 deleted */
    uint8_t segmentation;
    uint16_t max_apdu;
    uint16_t vendor_id;
    BACNET_ADDRESS address;
} bp_device_entry_t;

typedef struct {
    bp_device_entry_t *entries;
    uint32_t capacity; /* power of two */
    uint32_t used;
    uint32_t deleted;
} bp_device_table_t;

/* ---- string storage for object names (stack keeps raw pointers) ------- */

typedef struct {
    uint64_t key;
    char *value;
    uint8_t state; /* 0 empty, 1 used, 2 deleted */
} bp_string_entry_t;

typedef struct {
    bp_string_entry_t *entries;
    uint32_t capacity;
    uint32_t used;
    uint32_t deleted;
} bp_string_table_t;

/* ---- outstanding confirmed requests ----------------------------------- */

typedef struct {
    bool active;
    uint8_t service;
    uint32_t device_id;
    BACNET_ADDRESS dest;
} bp_transaction_t;

/* ---- engine state ------------------------------------------------------ */

static struct {
    bool initialized;
    bool server_enabled;
    bool strict_source;
    bool suppress_write_events;
    uint32_t last_ms;
    uint32_t second_acc;
    uint32_t object_acc;
    uint32_t cov_scan_last;
    uint32_t cov_scan_interval_ms;
    uint32_t cov_scan_budget;
    /* foreign device registration */
    BACNET_IP_ADDRESS fdr_bbmd;
    uint16_t fdr_ttl;
    uint32_t fdr_elapsed;
    /* event buffer */
    uint8_t *ev_buf;
    uint32_t ev_len;
    uint32_t ev_cap;
    uint32_t ev_max;
    /* tables */
    bp_device_table_t devices;
    bp_string_table_t strings;
    bp_transaction_t tx[256];
    bp_stats_t stats;
    /* buffers */
    uint8_t rx_buf[MAX_MPDU + 16];
    uint8_t tx_buf[MAX_PDU];
} g;

static bp_socket_t g_wake_sock = BP_INVALID_SOCKET;
static struct sockaddr_in g_wake_addr;
static bp_atomic_t g_wake_pending;
static int g_socket_buffer_size;

/* ---- event buffer ------------------------------------------------------ */

static bool bp_event_reserve(uint32_t needed)
{
    uint32_t capacity;
    uint8_t *buffer;

    if (g.ev_len + needed <= g.ev_cap) {
        return true;
    }
    if (g.ev_len + needed > g.ev_max) {
        return false;
    }
    capacity = g.ev_cap ? g.ev_cap : 64u * 1024u;
    while (capacity < g.ev_len + needed) {
        capacity *= 2;
    }
    if (capacity > g.ev_max) {
        capacity = g.ev_max;
    }
    buffer = (uint8_t *)realloc(g.ev_buf, capacity);
    if (!buffer) {
        return false;
    }
    g.ev_buf = buffer;
    g.ev_cap = capacity;
    return true;
}

static void bp_event_src(bp_event_header_t *hdr, const BACNET_ADDRESS *src)
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

static void bp_event_push(
    bp_event_header_t *hdr, const uint8_t *data, uint32_t data_len)
{
    uint32_t needed;

    if (data_len > 0xFFFFu) {
        data_len = 0xFFFFu;
    }
    hdr->data_len = (uint16_t)data_len;
    needed = (uint32_t)sizeof(*hdr) + data_len;
    if (!bp_event_reserve(needed)) {
        g.stats.events_dropped++;
        return;
    }
    memcpy(&g.ev_buf[g.ev_len], hdr, sizeof(*hdr));
    if (data_len && data) {
        memcpy(&g.ev_buf[g.ev_len + sizeof(*hdr)], data, data_len);
    }
    g.ev_len += needed;
}

static void bp_event_init(bp_event_header_t *hdr, uint8_t kind)
{
    memset(hdr, 0, sizeof(*hdr));
    hdr->kind = kind;
    hdr->device_id = BP_DEVICE_UNKNOWN;
    hdr->d = -1;
}

static void bp_log(int level, const char *format, ...)
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

/* ---- device table ------------------------------------------------------ */

static uint32_t bp_hash32(uint32_t x)
{
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

static bp_device_entry_t *bp_device_find(uint32_t device_id)
{
    uint32_t mask;
    uint32_t i;

    if (!g.devices.entries) {
        return NULL;
    }
    mask = g.devices.capacity - 1;
    for (i = bp_hash32(device_id) & mask;; i = (i + 1) & mask) {
        bp_device_entry_t *e = &g.devices.entries[i];
        if (e->state == 0) {
            return NULL;
        }
        if (e->state == 1 && e->device_id == device_id) {
            return e;
        }
    }
}

static bool bp_device_rehash(uint32_t capacity)
{
    bp_device_entry_t *old = g.devices.entries;
    uint32_t old_capacity = g.devices.capacity;
    uint32_t i;

    g.devices.entries =
        (bp_device_entry_t *)calloc(capacity, sizeof(bp_device_entry_t));
    if (!g.devices.entries) {
        g.devices.entries = old;
        return false;
    }
    g.devices.capacity = capacity;
    g.devices.used = 0;
    g.devices.deleted = 0;
    for (i = 0; i < old_capacity; i++) {
        if (old[i].state == 1) {
            uint32_t mask = capacity - 1;
            uint32_t j = bp_hash32(old[i].device_id) & mask;
            while (g.devices.entries[j].state != 0) {
                j = (j + 1) & mask;
            }
            g.devices.entries[j] = old[i];
            g.devices.used++;
        }
    }
    free(old);
    return true;
}

static bp_device_entry_t *bp_device_put(
    uint32_t device_id, const BACNET_ADDRESS *address, uint16_t max_apdu)
{
    bp_device_entry_t *e = bp_device_find(device_id);
    uint32_t mask;
    uint32_t i;

    if (!e) {
        if (!g.devices.entries ||
            (g.devices.used + g.devices.deleted + 1) * 4 >
                g.devices.capacity * 3) {
            uint32_t capacity = g.devices.capacity ? g.devices.capacity : 256;
            if ((g.devices.used + 1) * 2 > capacity) {
                capacity *= 2;
            }
            if (!bp_device_rehash(capacity)) {
                return NULL;
            }
        }
        mask = g.devices.capacity - 1;
        for (i = bp_hash32(device_id) & mask;; i = (i + 1) & mask) {
            e = &g.devices.entries[i];
            if (e->state != 1) {
                if (e->state == 2) {
                    g.devices.deleted--;
                }
                break;
            }
        }
        memset(e, 0, sizeof(*e));
        e->state = 1;
        e->device_id = device_id;
        g.devices.used++;
    }
    bacnet_address_copy(&e->address, address);
    e->max_apdu = max_apdu ? max_apdu : MAX_APDU;
    return e;
}

static void bp_device_remove(uint32_t device_id)
{
    bp_device_entry_t *e = bp_device_find(device_id);

    if (e) {
        e->state = 2;
        g.devices.used--;
        g.devices.deleted++;
    }
}

/* ---- string table ------------------------------------------------------ */

static uint64_t bp_string_key(uint16_t type, uint32_t instance, uint8_t slot)
{
    return ((uint64_t)slot << 48) | ((uint64_t)type << 32) | instance;
}

static uint32_t bp_hash64(uint64_t key)
{
    return bp_hash32((uint32_t)key ^ bp_hash32((uint32_t)(key >> 32)));
}

static bp_string_entry_t *bp_string_slot(uint64_t key, bool insert)
{
    uint32_t mask;
    uint32_t i;
    bp_string_entry_t *tombstone = NULL;

    if (insert &&
        (!g.strings.entries ||
         (g.strings.used + g.strings.deleted + 1) * 4 >
             g.strings.capacity * 3)) {
        bp_string_entry_t *old = g.strings.entries;
        uint32_t old_capacity = g.strings.capacity;
        uint32_t capacity = old_capacity ? old_capacity : 64;
        if ((g.strings.used + 1) * 2 > capacity) {
            capacity *= 2;
        }
        g.strings.entries =
            (bp_string_entry_t *)calloc(capacity, sizeof(bp_string_entry_t));
        if (!g.strings.entries) {
            g.strings.entries = old;
            return NULL;
        }
        g.strings.capacity = capacity;
        g.strings.used = 0;
        g.strings.deleted = 0;
        for (i = 0; i < old_capacity; i++) {
            if (old[i].state == 1) {
                uint32_t j = bp_hash64(old[i].key) & (capacity - 1);
                while (g.strings.entries[j].state != 0) {
                    j = (j + 1) & (capacity - 1);
                }
                g.strings.entries[j] = old[i];
                g.strings.used++;
            }
        }
        free(old);
    }
    if (!g.strings.entries) {
        return NULL;
    }
    mask = g.strings.capacity - 1;
    for (i = bp_hash64(key) & mask;; i = (i + 1) & mask) {
        bp_string_entry_t *e = &g.strings.entries[i];
        if (e->state == 0) {
            if (!insert) {
                return NULL;
            }
            if (tombstone) {
                g.strings.deleted--;
                e = tombstone;
            }
            e->state = 1;
            e->key = key;
            e->value = NULL;
            g.strings.used++;
            return e;
        }
        if (e->state == 2) {
            if (!tombstone) {
                tombstone = e;
            }
        } else if (e->key == key) {
            return e;
        }
    }
}

/** Stores a copy of value and returns the stable pointer (old one freed
 *  by the caller via the returned previous pointer). */
static char *bp_string_store(uint64_t key, const char *value, char **previous)
{
    bp_string_entry_t *e = bp_string_slot(key, true);
    size_t len;
    char *copy;

    *previous = NULL;
    if (!e) {
        return NULL;
    }
    len = strlen(value);
    copy = (char *)malloc(len + 1);
    if (!copy) {
        return NULL;
    }
    memcpy(copy, value, len + 1);
    *previous = e->value;
    e->value = copy;
    return copy;
}

/** Like bp_string_store() for a buffer that may contain NUL bytes. */
static char *bp_bytes_store(
    uint64_t key, const char *value, uint32_t len, char **previous)
{
    bp_string_entry_t *e = bp_string_slot(key, true);
    char *copy;

    *previous = NULL;
    if (!e) {
        return NULL;
    }
    copy = (char *)malloc(len + 2);
    if (!copy) {
        return NULL;
    }
    memcpy(copy, value, len);
    copy[len] = 0;
    copy[len + 1] = 0;
    *previous = e->value;
    e->value = copy;
    return copy;
}

static void bp_string_remove(uint64_t key)
{
    bp_string_entry_t *e = bp_string_slot(key, false);

    if (e) {
        free(e->value);
        e->value = NULL;
        e->state = 2;
        g.strings.used--;
        g.strings.deleted++;
    }
}

static void bp_string_clear(void)
{
    uint32_t i;

    for (i = 0; i < g.strings.capacity; i++) {
        if (g.strings.entries[i].state == 1) {
            free(g.strings.entries[i].value);
        }
    }
    free(g.strings.entries);
    memset(&g.strings, 0, sizeof(g.strings));
}

/* ---- wakeup socket ----------------------------------------------------- */

static void bp_set_nonblocking(bp_socket_t sock)
{
#if defined(_WIN32)
    u_long mode = 1;
    ioctlsocket(sock, FIONBIO, &mode);
#else
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);
    }
    fcntl(sock, F_SETFD, FD_CLOEXEC);
#endif
}

static bool bp_wake_init(void)
{
    bp_socket_t sock;
    struct sockaddr_in addr;
#if defined(_WIN32)
    int len = sizeof(addr);
#else
    socklen_t len = sizeof(addr);
#endif

    if (g_wake_sock != BP_INVALID_SOCKET) {
        return true;
    }
    sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == BP_INVALID_SOCKET) {
        return false;
    }
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        getsockname(sock, (struct sockaddr *)&addr, &len) != 0) {
        bp_close_socket(sock);
        return false;
    }
    bp_set_nonblocking(sock);
    g_wake_addr = addr;
    /* the socket is intentionally never closed: bacnet_plugin_wakeup() may
       race with shutdown from another thread */
    g_wake_sock = sock;
    return true;
}

static void bp_wake_drain(void)
{
    char buffer[64];

    if (g_wake_sock == BP_INVALID_SOCKET) {
        return;
    }
    while (recv(g_wake_sock, buffer, sizeof(buffer), 0) > 0) {
    }
    /* clear after draining: a concurrent wakeup either left a datagram in
       the socket or its message is already queued for the caller */
    (void)bp_atomic_exchange(&g_wake_pending, 0);
}

BP_API void bacnet_plugin_wakeup(void)
{
    bp_socket_t sock = g_wake_sock;

    if (sock == BP_INVALID_SOCKET) {
        return;
    }
    if (bp_atomic_exchange(&g_wake_pending, 1) == 0) {
        (void)sendto(
            sock, "w", 1, 0, (const struct sockaddr *)&g_wake_addr,
            sizeof(g_wake_addr));
    }
}

static void bp_wait(uint32_t timeout_ms)
{
    int bip = bip_get_socket();
    int bcast = bip_get_broadcast_socket();
#if defined(_WIN32)
    fd_set fds;
    struct timeval tv;

    FD_ZERO(&fds);
    if (bip >= 0) {
        FD_SET((SOCKET)bip, &fds);
    }
    if (bcast >= 0 && bcast != bip) {
        FD_SET((SOCKET)bcast, &fds);
    }
    if (g_wake_sock != BP_INVALID_SOCKET) {
        FD_SET(g_wake_sock, &fds);
    }
    tv.tv_sec = (long)(timeout_ms / 1000);
    tv.tv_usec = (long)((timeout_ms % 1000) * 1000);
    (void)select(0, &fds, NULL, NULL, &tv);
#else
    struct pollfd fds[3];
    nfds_t n = 0;

    if (bip >= 0) {
        fds[n].fd = bip;
        fds[n].events = POLLIN;
        fds[n++].revents = 0;
    }
    if (bcast >= 0 && bcast != bip) {
        fds[n].fd = bcast;
        fds[n].events = POLLIN;
        fds[n++].revents = 0;
    }
    if (g_wake_sock != BP_INVALID_SOCKET) {
        fds[n].fd = g_wake_sock;
        fds[n].events = POLLIN;
        fds[n++].revents = 0;
    }
    (void)poll(fds, n, (int)timeout_ms);
#endif
}

/* ---- client side handlers ---------------------------------------------- */

static bp_transaction_t *bp_tx_for(uint8_t invoke_id)
{
    bp_transaction_t *tx = &g.tx[invoke_id];

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
        len = npdu_encode_pdu(&g.tx_buf[0], src, &my_address, &npdu_data);
        len += abort_encode_apdu(
            &g.tx_buf[len], service_data->invoke_id,
            ABORT_REASON_SEGMENTATION_NOT_SUPPORTED, false);
        (void)datalink_send_pdu(src, &npdu_data, &g.tx_buf[0], len);
    } else {
        bp_event_push(&hdr, service_request, service_len);
    }
    tx->active = false;
}

static void bp_on_simple_ack(BACNET_ADDRESS *src, uint8_t invoke_id)
{
    bp_transaction_t *tx = bp_tx_for(invoke_id);

    if (tx) {
        bp_tx_event(tx, BP_EVENT_SIMPLE_ACK, invoke_id, src);
        tx->active = false;
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
    tx->active = false;
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
    tx->active = false;
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
    tx->active = false;
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
    tx->active = false;
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
    tx->active = false;
    g.stats.timeouts++;
    /* a failed transaction keeps its TSM slot until freed */
    tsm_free_invoke_id(invoke_id);
}

static void bp_on_i_am(
    uint8_t *service_request, uint16_t service_len, BACNET_ADDRESS *src)
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
    if (g.server_enabled && device_id == Device_Object_Instance_Number()) {
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

#define BP_UNCONFIRMED_FORWARDER(name, service)                              \
    static void name(uint8_t *request, uint16_t len, BACNET_ADDRESS *src)   \
    {                                                                        \
        bp_forward_unconfirmed((service), request, len, src);               \
    }

BP_UNCONFIRMED_FORWARDER(bp_on_ucov, SERVICE_UNCONFIRMED_COV_NOTIFICATION)
BP_UNCONFIRMED_FORWARDER(bp_on_i_have, SERVICE_UNCONFIRMED_I_HAVE)
BP_UNCONFIRMED_FORWARDER(
    bp_on_uevent, SERVICE_UNCONFIRMED_EVENT_NOTIFICATION)
BP_UNCONFIRMED_FORWARDER(
    bp_on_utext, SERVICE_UNCONFIRMED_TEXT_MESSAGE)
BP_UNCONFIRMED_FORWARDER(
    bp_on_uprivate, SERVICE_UNCONFIRMED_PRIVATE_TRANSFER)

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
    len = npdu_encode_pdu(&g.tx_buf[0], src, &my_address, &npdu_data);
    if (service_data->segmented_message) {
        len += abort_encode_apdu(
            &g.tx_buf[len], service_data->invoke_id,
            ABORT_REASON_SEGMENTATION_NOT_SUPPORTED, true);
    } else if (service_len == 0) {
        len += reject_encode_apdu(
            &g.tx_buf[len], service_data->invoke_id,
            REJECT_REASON_MISSING_REQUIRED_PARAMETER);
    } else {
        len += encode_simple_ack(
            &g.tx_buf[len], service_data->invoke_id, service);
        bp_event_init(&hdr, BP_EVENT_CONFIRMED_NOTIFICATION);
        hdr.service = service;
        hdr.invoke_id = service_data->invoke_id;
        bp_event_src(&hdr, src);
        bp_event_push(&hdr, service_request, service_len);
    }
    (void)datalink_send_pdu(src, &npdu_data, &g.tx_buf[0], len);
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
        SERVICE_CONFIRMED_EVENT_NOTIFICATION, service_request, service_len,
        src, service_data);
}

/* ---- server side ------------------------------------------------------- */

static bool bp_on_write_store(BACNET_WRITE_PROPERTY_DATA *wp_data)
{
    bp_event_header_t hdr;

    if (g.suppress_write_events || !wp_data) {
        return true;
    }
    bp_event_init(&hdr, BP_EVENT_WRITE);
    hdr.a = (uint32_t)wp_data->object_type;
    hdr.b = wp_data->object_instance;
    hdr.c = (uint32_t)wp_data->object_property;
    hdr.d = (wp_data->array_index == BACNET_ARRAY_ALL)
        ? -1
        : (int32_t)wp_data->array_index;
    hdr.priority = wp_data->priority;
    bp_event_push(
        &hdr, wp_data->application_data,
        wp_data->application_data_len > 0
            ? (uint32_t)wp_data->application_data_len
            : 0);
    return true;
}

static void bp_cov_scan(uint32_t now)
{
    uint32_t budget;

    if (!g.server_enabled) {
        return;
    }
    if ((uint32_t)(now - g.cov_scan_last) < g.cov_scan_interval_ms) {
        return;
    }
    g.cov_scan_last = now;
    budget = g.cov_scan_budget;
    /* run one complete detection/notification cycle (4 steps per
       subscription); handler_cov_task() only performs a single step */
    while (budget-- > 0) {
        if (handler_cov_fsm()) {
            break;
        }
    }
}

/* ---- timers ------------------------------------------------------------ */

static void bp_timers(void)
{
    uint32_t now = (uint32_t)mstimer_now();
    uint32_t elapsed = now - g.last_ms;

    if (elapsed > 0) {
        g.last_ms = now;
        tsm_timer_milliseconds((uint16_t)(elapsed > 0xFFFF ? 0xFFFF : elapsed));
        g.second_acc += elapsed;
        if (g.second_acc >= 1000) {
            uint32_t seconds = g.second_acc / 1000;
            g.second_acc %= 1000;
            datalink_maintenance_timer((uint16_t)seconds);
            dcc_timer_seconds(seconds);
            if (g.server_enabled) {
                handler_cov_timer_seconds(seconds);
                trend_log_timer((uint16_t)seconds);
            }
            if (g.fdr_ttl > 0) {
                uint32_t renew = g.fdr_ttl > 20 ? (uint32_t)g.fdr_ttl / 2 : 10;
                g.fdr_elapsed += seconds;
                if (g.fdr_elapsed >= renew) {
                    g.fdr_elapsed = 0;
                    (void)bvlc_register_with_bbmd(&g.fdr_bbmd, g.fdr_ttl);
                }
            }
        }
        if (g.server_enabled) {
            g.object_acc += elapsed;
            if (g.object_acc >= 100) {
                Device_Timer(
                    (uint16_t)(g.object_acc > 0xFFFF ? 0xFFFF : g.object_acc));
                g.object_acc = 0;
            }
        }
    }
    bp_cov_scan(now);
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

    if (!g.strict_source || len < 2 || pdu[0] != BACNET_PROTOCOL_VERSION) {
        return true;
    }
    bacnet_address_copy(&full_src, src);
    memset(&dest, 0, sizeof(dest));
    memset(&npdu_data, 0, sizeof(npdu_data));
    offset = bacnet_npdu_decode(pdu, len, &dest, &full_src, &npdu_data);
    if (offset <= 0 || offset + 2 > len || npdu_data.network_layer_message) {
        return true;
    }
    type = pdu[offset] & 0xF0;
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
    if (tx && !bacnet_address_same(&tx->dest, &full_src)) {
        BACNET_ADDRESS tsm_dest;
        BACNET_NPDU_DATA tsm_npdu;
        uint16_t tsm_len = 0;

        if (!tsm_get_transaction_pdu(
                pdu[offset + 1], &tsm_dest, &tsm_npdu, &g.tx_buf[0],
                &tsm_len) ||
            !bacnet_address_same(&tsm_dest, &tx->dest)) {
            /* our transaction ended without notice: the invoke id now
               belongs to another transaction of the stack */
            tx->active = false;
            return true;
        }
        /* reply for a recycled invoke id from another device: dropping it
           prevents completing a request with foreign data */
        g.stats.replies_dropped++;
        return false;
    }
    return true;
}

BP_API int32_t bacnet_plugin_poll(uint32_t timeout_ms, uint32_t max_packets)
{
    int32_t processed = 0;

    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    g.stats.poll_calls++;
    bp_timers();
    if (timeout_ms > 0) {
        bp_wait(timeout_ms);
    }
    bp_wake_drain();
    while ((uint32_t)processed < max_packets) {
        BACNET_ADDRESS src;
        uint16_t len;

        memset(&src, 0, sizeof(src));
        len = bip_receive(&src, g.rx_buf, MAX_MPDU, 0);
        if (len == 0) {
            break;
        }
        processed++;
        g.stats.packets_received++;
        if (bp_accept_reply(&src, g.rx_buf, len)) {
            npdu_handler(&src, g.rx_buf, len);
        }
    }
    bp_timers();
    return processed;
}

/* ---- lifecycle --------------------------------------------------------- */

BP_API const char *bacnet_plugin_version(void)
{
    return "bacnet_plugin/" BP_ENGINE_VERSION
           " bacnet-stack/" BACNET_VERSION_TEXT;
}

#if defined(_WIN32)
void bp_port_set_socket_buffer_size(int bytes)
{
    g_socket_buffer_size = bytes;
}

static void bp_apply_socket_buffer(int sock)
{
    if (sock >= 0 && g_socket_buffer_size > 0) {
        int size = g_socket_buffer_size;
        setsockopt(
            (SOCKET)sock, SOL_SOCKET, SO_RCVBUF, (const char *)&size,
            sizeof(size));
        setsockopt(
            (SOCKET)sock, SOL_SOCKET, SO_SNDBUF, (const char *)&size,
            sizeof(size));
    }
}
#endif

static void bp_register_client_handlers(void)
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
    apdu_set_unrecognized_service_handler_handler(
        handler_unrecognized_service);
    apdu_set_unconfirmed_handler(SERVICE_UNCONFIRMED_I_AM, bp_on_i_am);
    apdu_set_unconfirmed_handler(
        SERVICE_UNCONFIRMED_COV_NOTIFICATION, bp_on_ucov);
    apdu_set_unconfirmed_handler(SERVICE_UNCONFIRMED_I_HAVE, bp_on_i_have);
    apdu_set_unconfirmed_handler(
        SERVICE_UNCONFIRMED_EVENT_NOTIFICATION, bp_on_uevent);
    apdu_set_unconfirmed_handler(
        SERVICE_UNCONFIRMED_TEXT_MESSAGE, bp_on_utext);
    apdu_set_unconfirmed_handler(
        SERVICE_UNCONFIRMED_PRIVATE_TRANSFER, bp_on_uprivate);
    apdu_set_confirmed_handler(
        SERVICE_CONFIRMED_COV_NOTIFICATION, bp_on_ccov);
    apdu_set_confirmed_handler(
        SERVICE_CONFIRMED_EVENT_NOTIFICATION, bp_on_cevent);
}

BP_API int32_t bacnet_plugin_init(
    const char *iface,
    uint16_t port,
    uint32_t device_instance,
    int32_t socket_buffer_bytes)
{
    if (g.initialized) {
        return BP_ERR_ALREADY_INITIALIZED;
    }
    memset(&g.stats, 0, sizeof(g.stats));
    memset(g.tx, 0, sizeof(g.tx));
    g.server_enabled = false;
    g.strict_source = true;
    g.suppress_write_events = false;
    if (g.cov_scan_interval_ms == 0) {
        g.cov_scan_interval_ms = 50;
    }
    if (g.cov_scan_budget == 0) {
        g.cov_scan_budget = 1u << 20;
    }
    if (g.ev_max == 0) {
        g.ev_max = 64u * 1024u * 1024u;
    }
    g.ev_len = 0;
    g_socket_buffer_size = socket_buffer_bytes > 0 ? socket_buffer_bytes : 0;
#if !defined(_WIN32)
    bp_port_set_socket_buffer_size(g_socket_buffer_size);
#endif

    mstimer_init();
    datetime_init();
    /* application objects only: no demo instances of the default table */
    Device_Init(BP_Object_Table);
    if (device_instance <= BACNET_MAX_INSTANCE) {
        (void)Device_Set_Object_Instance_Number(device_instance);
    }
    address_init();
    address_own_device_id_set(Device_Object_Instance_Number());
    bp_register_client_handlers();

    bip_set_port(port ? port : 0xBAC0);
    if (!bip_init(iface && *iface ? iface : NULL)) {
        return BP_ERR_DATALINK;
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
    g.last_ms = (uint32_t)mstimer_now();
    g.cov_scan_last = g.last_ms;
    g.second_acc = 0;
    g.object_acc = 0;
    g.fdr_ttl = 0;
    g.initialized = true;
    return BP_OK;
}

BP_API void bacnet_plugin_shutdown(void)
{
    unsigned invoke_id;

    if (!g.initialized) {
        return;
    }
    for (invoke_id = 1; invoke_id < 256; invoke_id++) {
        if (g.tx[invoke_id].active) {
            tsm_free_invoke_id((uint8_t)invoke_id);
        }
    }
    memset(g.tx, 0, sizeof(g.tx));
    Device_Write_Property_Store_Callback_Set(NULL);
    if (g.server_enabled) {
        Device_Delete_Objects();
    }
    bip_cleanup();
    free(g.devices.entries);
    memset(&g.devices, 0, sizeof(g.devices));
    bp_string_clear();
    free(g.ev_buf);
    g.ev_buf = NULL;
    g.ev_len = 0;
    g.ev_cap = 0;
    g.server_enabled = false;
    g.fdr_ttl = 0;
    g.initialized = false;
}

BP_API int32_t bacnet_plugin_set_option(int32_t option, int64_t value)
{
    switch (option) {
        case BP_OPTION_STRICT_SOURCE:
            g.strict_source = value != 0;
            return BP_OK;
        case BP_OPTION_COV_SCAN_INTERVAL_MS:
            if (value < 1 || value > 60000) {
                return BP_ERR_INVALID_ARGUMENT;
            }
            g.cov_scan_interval_ms = (uint32_t)value;
            return BP_OK;
        case BP_OPTION_MAX_EVENT_BUFFER:
            if (value < 64 * 1024 || value > 0x7FFFFFFF) {
                return BP_ERR_INVALID_ARGUMENT;
            }
            g.ev_max = (uint32_t)value;
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
            g.cov_scan_budget = (uint32_t)value;
            return BP_OK;
        default:
            return BP_ERR_INVALID_ARGUMENT;
    }
}

BP_API const uint8_t *bacnet_plugin_events_data(void)
{
    return g.ev_buf;
}

BP_API uint32_t bacnet_plugin_events_length(void)
{
    return g.ev_len;
}

BP_API void bacnet_plugin_events_clear(void)
{
    g.ev_len = 0;
}

BP_API void bacnet_plugin_stats(bp_stats_t *out)
{
    if (!out) {
        return;
    }
    *out = g.stats;
    out->tsm_idle = g.initialized ? tsm_transaction_idle_count() : 0;
    out->bound_devices = g.devices.used;
    out->event_buffer_capacity = g.ev_cap;
}

/* ---- client API -------------------------------------------------------- */

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

    if (!g.initialized) {
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
    pdu_len = npdu_encode_pdu(&g.tx_buf[0], &dest, &my_address, &npdu_data);
    if (pdu_len <= 0 || pdu_len + apdu_len > (int)sizeof(g.tx_buf)) {
        tsm_free_invoke_id(invoke_id);
        return BP_ERR_APDU_TOO_LARGE;
    }
    g.tx_buf[pdu_len] = PDU_TYPE_CONFIRMED_SERVICE_REQUEST;
    g.tx_buf[pdu_len + 1] = encode_max_segs_max_apdu(0, MAX_APDU);
    g.tx_buf[pdu_len + 2] = invoke_id;
    g.tx_buf[pdu_len + 3] = service;
    if (data_len) {
        memcpy(&g.tx_buf[pdu_len + 4], data, data_len);
    }
    pdu_len += apdu_len;
    tsm_set_confirmed_unsegmented_transaction(
        invoke_id, &dest, &npdu_data, &g.tx_buf[0], (uint16_t)pdu_len);
    g.tx[invoke_id].active = true;
    g.tx[invoke_id].service = service;
    g.tx[invoke_id].device_id = device_id;
    bacnet_address_copy(&g.tx[invoke_id].dest, &dest);
    sent = datalink_send_pdu(&dest, &npdu_data, &g.tx_buf[0], pdu_len);
    g.stats.requests_sent++;
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

    if (!g.initialized) {
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
    pdu_len = npdu_encode_pdu(&g.tx_buf[0], &dest, &my_address, &npdu_data);
    if (pdu_len <= 0 || pdu_len + 2 + data_len > MAX_PDU ||
        2 + data_len > MAX_APDU) {
        return BP_ERR_APDU_TOO_LARGE;
    }
    g.tx_buf[pdu_len++] = PDU_TYPE_UNCONFIRMED_SERVICE_REQUEST;
    g.tx_buf[pdu_len++] = service;
    if (data_len) {
        memcpy(&g.tx_buf[pdu_len], data, data_len);
        pdu_len += data_len;
    }
    g.stats.requests_sent++;
    if (datalink_send_pdu(&dest, &npdu_data, &g.tx_buf[0], pdu_len) <= 0) {
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

    if (!g.initialized) {
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

    if (!g.initialized) {
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
    g.fdr_bbmd = bbmd;
    g.fdr_ttl = ttl_seconds;
    g.fdr_elapsed = 0;
    return BP_OK;
}

/* ---- server API -------------------------------------------------------- */

BP_API int32_t
bacnet_plugin_server_enable(uint32_t device_instance, const char *device_name)
{
    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (device_instance > BACNET_MAX_INSTANCE - 1) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    if (!Device_Set_Object_Instance_Number(device_instance)) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    if (device_name && *device_name) {
        (void)Device_Object_Name_ANSI_Init(device_name);
    }
    address_own_device_id_set(device_instance);
    bp_device_remove(device_instance);
    if (!g.server_enabled) {
        apdu_set_unconfirmed_handler(
            SERVICE_UNCONFIRMED_WHO_IS, handler_who_is);
        apdu_set_unconfirmed_handler(
            SERVICE_UNCONFIRMED_WHO_HAS, handler_who_has);
        apdu_set_unconfirmed_handler(
            SERVICE_UNCONFIRMED_TIME_SYNCHRONIZATION, handler_timesync);
        apdu_set_unconfirmed_handler(
            SERVICE_UNCONFIRMED_UTC_TIME_SYNCHRONIZATION,
            handler_timesync_utc);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_READ_PROPERTY, handler_read_property);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_READ_PROP_MULTIPLE,
            handler_read_property_multiple);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_WRITE_PROPERTY, handler_write_property);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_WRITE_PROP_MULTIPLE,
            handler_write_property_multiple);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_READ_RANGE, handler_read_range);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_SUBSCRIBE_COV, handler_cov_subscribe);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_SUBSCRIBE_COV_PROPERTY, handler_cov_subscribe);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_DEVICE_COMMUNICATION_CONTROL,
            handler_device_communication_control);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_REINITIALIZE_DEVICE,
            handler_reinitialize_device);
        handler_cov_init();
        Device_Write_Property_Store_Callback_Set(bp_on_write_store);
        g.server_enabled = true;
    }
    Send_I_Am(&Handler_Transmit_Buffer[0]);
    return BP_OK;
}

BP_API int32_t bacnet_plugin_device_set_string(uint32_t property, const char *value)
{
    char *previous = NULL;
    char *stored;
    size_t len;
    bool ok;

    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!value) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    /* some setters keep the pointer (vendor name): keep a stable copy */
    stored = bp_string_store(
        bp_string_key(OBJECT_DEVICE, property, 3), value, &previous);
    if (!stored) {
        return BP_ERR_NO_MEMORY;
    }
    len = strlen(stored);
    switch (property) {
        case PROP_OBJECT_NAME:
            ok = Device_Object_Name_ANSI_Init(stored);
            break;
        case PROP_VENDOR_NAME:
            ok = Device_Set_Vendor_Name(stored, len);
            break;
        case PROP_MODEL_NAME:
            ok = Device_Set_Model_Name(stored, len);
            break;
        case PROP_DESCRIPTION:
            ok = Device_Set_Description(stored, len);
            break;
        case PROP_LOCATION:
            ok = Device_Set_Location(stored, len);
            break;
        case PROP_FIRMWARE_REVISION:
            ok = Device_Set_Firmware_Revision(stored, len);
            break;
        case PROP_APPLICATION_SOFTWARE_VERSION:
            ok = Device_Set_Application_Software_Version(stored, len);
            break;
        default:
            free(previous);
            return BP_ERR_UNSUPPORTED;
    }
    if (!ok) {
        /* the previous value (if any) is still referenced: keep it */
        bp_string_entry_t *e =
            bp_string_slot(bp_string_key(OBJECT_DEVICE, property, 3), false);
        if (e && previous) {
            e->value = previous;
            free(stored);
        }
        return BP_ERR_INVALID_ARGUMENT;
    }
    free(previous);
    return BP_OK;
}

BP_API int32_t bacnet_plugin_device_set_vendor_id(uint16_t vendor_id)
{
    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    Device_Set_Vendor_Identifier(vendor_id);
    return BP_OK;
}

BP_API int32_t bacnet_plugin_send_i_am(void)
{
    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!g.server_enabled) {
        return BP_ERR_SERVER_DISABLED;
    }
    Send_I_Am(&Handler_Transmit_Buffer[0]);
    return BP_OK;
}

BP_API int64_t bacnet_plugin_object_create(
    uint16_t object_type,
    uint32_t instance,
    uint32_t *error_class,
    uint32_t *error_code)
{
    BACNET_CREATE_OBJECT_DATA data;

    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!g.server_enabled) {
        return BP_ERR_SERVER_DISABLED;
    }
    memset(&data, 0, sizeof(data));
    data.object_type = (BACNET_OBJECT_TYPE)object_type;
    data.object_instance = instance;
    if (Device_Create_Object(&data)) {
        /* value objects are writable by clients like their BACnet
           definition requires; bacnet-stack disables it by default */
        switch (data.object_type) {
            case OBJECT_BINARY_VALUE:
                Binary_Value_Write_Enable(data.object_instance);
                break;
            case OBJECT_MULTI_STATE_VALUE:
                Multistate_Value_Write_Enable(data.object_instance);
                break;
            default:
                break;
        }
        return (int64_t)data.object_instance;
    }
    if (error_class) {
        *error_class = (uint32_t)data.error_class;
    }
    if (error_code) {
        *error_code = (uint32_t)data.error_code;
    }
    return BP_ERR_OBJECT;
}

BP_API int32_t
bacnet_plugin_object_delete(uint16_t object_type, uint32_t instance)
{
    BACNET_DELETE_OBJECT_DATA data;

    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    memset(&data, 0, sizeof(data));
    data.object_type = (BACNET_OBJECT_TYPE)object_type;
    data.object_instance = instance;
    if (!Device_Delete_Object(&data)) {
        return BP_ERR_OBJECT;
    }
    bp_string_remove(bp_string_key(object_type, instance, 0));
    bp_string_remove(bp_string_key(object_type, instance, 1));
    bp_string_remove(bp_string_key(object_type, instance, 2));
    return BP_OK;
}

typedef bool (*bp_name_setter_t)(uint32_t, const char *);

static bp_name_setter_t bp_name_setter(uint16_t type, bool description)
{
    switch (type) {
        case OBJECT_ANALOG_INPUT:
            return description ? Analog_Input_Description_Set
                               : Analog_Input_Name_Set;
        case OBJECT_ANALOG_OUTPUT:
            return description ? Analog_Output_Description_Set
                               : Analog_Output_Name_Set;
        case OBJECT_ANALOG_VALUE:
            return description ? Analog_Value_Description_Set
                               : Analog_Value_Name_Set;
        case OBJECT_BINARY_INPUT:
            return description ? Binary_Input_Description_Set
                               : Binary_Input_Name_Set;
        case OBJECT_BINARY_OUTPUT:
            return description ? Binary_Output_Description_Set
                               : Binary_Output_Name_Set;
        case OBJECT_BINARY_VALUE:
            return description ? Binary_Value_Description_Set
                               : Binary_Value_Name_Set;
        case OBJECT_MULTI_STATE_INPUT:
            return description ? Multistate_Input_Description_Set
                               : Multistate_Input_Name_Set;
        case OBJECT_MULTI_STATE_OUTPUT:
            return description ? Multistate_Output_Description_Set
                               : Multistate_Output_Name_Set;
        case OBJECT_MULTI_STATE_VALUE:
            return description ? Multistate_Value_Description_Set
                               : Multistate_Value_Name_Set;
        case OBJECT_INTEGER_VALUE:
            return description ? Integer_Value_Description_Set
                               : Integer_Value_Name_Set;
        case OBJECT_POSITIVE_INTEGER_VALUE:
            return description ? NULL : PositiveInteger_Value_Name_Set;
        case OBJECT_CHARACTERSTRING_VALUE:
            return description ? CharacterString_Value_Description_Set
                               : CharacterString_Value_Name_Set;
        default:
            return NULL;
    }
}

static int32_t bp_object_set_text(
    uint16_t object_type, uint32_t instance, const char *text, uint8_t slot)
{
    bp_name_setter_t setter;
    char *previous = NULL;
    char *stored;
    uint64_t key;

    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!text) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    setter = bp_name_setter(object_type, slot == 1);
    if (!setter) {
        return BP_ERR_UNSUPPORTED;
    }
    key = bp_string_key(object_type, instance, slot);
    stored = bp_string_store(key, text, &previous);
    if (!stored) {
        return BP_ERR_NO_MEMORY;
    }
    if (!setter(instance, stored)) {
        /* restore the previous pointer which the object still uses */
        if (previous) {
            bp_string_entry_t *e = bp_string_slot(key, false);
            if (e) {
                e->value = previous;
            }
            free(stored);
        } else {
            bp_string_remove(key);
        }
        return BP_ERR_OBJECT;
    }
    free(previous);
    if (slot == 0) {
        Device_Inc_Database_Revision();
    }
    return BP_OK;
}

BP_API int32_t bacnet_plugin_object_set_name(
    uint16_t object_type, uint32_t instance, const char *name)
{
    return bp_object_set_text(object_type, instance, name, 0);
}

BP_API int32_t bacnet_plugin_object_set_description(
    uint16_t object_type, uint32_t instance, const char *description)
{
    return bp_object_set_text(object_type, instance, description, 1);
}

static unsigned bp_priority(uint8_t priority)
{
    return (priority >= BACNET_MIN_PRIORITY && priority <= BACNET_MAX_PRIORITY)
        ? priority
        : BACNET_MAX_PRIORITY;
}

static int32_t bp_set_present_value(
    uint16_t object_type, uint32_t instance, double value, uint8_t priority)
{
    unsigned prio = bp_priority(priority);
    bool relinquish = isnan(value);
    bool ok = false;
    BACNET_BINARY_PV binary = (value != 0.0) ? BINARY_ACTIVE : BINARY_INACTIVE;

    switch (object_type) {
        case OBJECT_ANALOG_INPUT:
            if (!Analog_Input_Valid_Instance(instance) || relinquish) {
                return BP_ERR_OBJECT;
            }
            Analog_Input_Present_Value_Set(instance, (float)value);
            return BP_OK;
        case OBJECT_ANALOG_OUTPUT:
            ok = relinquish
                ? Analog_Output_Present_Value_Relinquish(instance, prio)
                : Analog_Output_Present_Value_Set(instance, (float)value, prio);
            break;
        case OBJECT_ANALOG_VALUE:
            ok = !relinquish &&
                Analog_Value_Present_Value_Set(
                     instance, (float)value, (uint8_t)prio);
            break;
        case OBJECT_BINARY_INPUT:
            ok = !relinquish && Binary_Input_Present_Value_Set(instance, binary);
            break;
        case OBJECT_BINARY_OUTPUT:
            ok = relinquish
                ? Binary_Output_Present_Value_Relinquish(instance, prio)
                : Binary_Output_Present_Value_Set(instance, binary, prio);
            break;
        case OBJECT_BINARY_VALUE:
            ok = !relinquish && Binary_Value_Present_Value_Set(instance, binary);
            break;
        case OBJECT_MULTI_STATE_INPUT:
            ok = !relinquish && value >= 1 &&
                Multistate_Input_Present_Value_Set(instance, (uint32_t)value);
            break;
        case OBJECT_MULTI_STATE_OUTPUT:
            ok = relinquish
                ? Multistate_Output_Present_Value_Relinquish(instance, prio)
                : (value >= 1 &&
                   Multistate_Output_Present_Value_Set(
                       instance, (uint32_t)value, prio));
            break;
        case OBJECT_MULTI_STATE_VALUE:
            ok = !relinquish && value >= 1 &&
                Multistate_Value_Present_Value_Set(instance, (uint32_t)value);
            break;
        case OBJECT_INTEGER_VALUE:
            ok = !relinquish &&
                Integer_Value_Present_Value_Set(
                     instance, (int32_t)value, (uint8_t)prio);
            break;
        case OBJECT_POSITIVE_INTEGER_VALUE:
            ok = !relinquish && value >= 0 &&
                PositiveInteger_Value_Present_Value_Set(
                     instance, (BACNET_UNSIGNED_INTEGER)value, (uint8_t)prio);
            break;
        default:
            return BP_ERR_UNSUPPORTED;
    }
    return ok ? BP_OK : BP_ERR_OBJECT;
}

BP_API int32_t bacnet_plugin_object_set_number(
    uint16_t object_type,
    uint32_t instance,
    uint32_t property,
    double value,
    uint8_t priority)
{
    bool flag = value != 0.0;

    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    switch (property) {
        case PROP_PRESENT_VALUE:
            return bp_set_present_value(object_type, instance, value, priority);
        case PROP_OUT_OF_SERVICE:
            switch (object_type) {
                case OBJECT_ANALOG_INPUT:
                    Analog_Input_Out_Of_Service_Set(instance, flag);
                    return BP_OK;
                case OBJECT_ANALOG_OUTPUT:
                    Analog_Output_Out_Of_Service_Set(instance, flag);
                    return BP_OK;
                case OBJECT_ANALOG_VALUE:
                    Analog_Value_Out_Of_Service_Set(instance, flag);
                    return BP_OK;
                case OBJECT_BINARY_INPUT:
                    Binary_Input_Out_Of_Service_Set(instance, flag);
                    return BP_OK;
                case OBJECT_BINARY_OUTPUT:
                    Binary_Output_Out_Of_Service_Set(instance, flag);
                    return BP_OK;
                case OBJECT_BINARY_VALUE:
                    Binary_Value_Out_Of_Service_Set(instance, flag);
                    return BP_OK;
                case OBJECT_MULTI_STATE_INPUT:
                    Multistate_Input_Out_Of_Service_Set(instance, flag);
                    return BP_OK;
                case OBJECT_MULTI_STATE_OUTPUT:
                    Multistate_Output_Out_Of_Service_Set(instance, flag);
                    return BP_OK;
                case OBJECT_MULTI_STATE_VALUE:
                    Multistate_Value_Out_Of_Service_Set(instance, flag);
                    return BP_OK;
                case OBJECT_INTEGER_VALUE:
                    Integer_Value_Out_Of_Service_Set(instance, flag);
                    return BP_OK;
                case OBJECT_CHARACTERSTRING_VALUE:
                    CharacterString_Value_Out_Of_Service_Set(instance, flag);
                    return BP_OK;
                default:
                    return BP_ERR_UNSUPPORTED;
            }
        case PROP_UNITS:
            switch (object_type) {
                case OBJECT_ANALOG_INPUT:
                    return Analog_Input_Units_Set(
                               instance, (BACNET_ENGINEERING_UNITS)value)
                        ? BP_OK
                        : BP_ERR_OBJECT;
                case OBJECT_ANALOG_OUTPUT:
                    return Analog_Output_Units_Set(
                               instance, (BACNET_ENGINEERING_UNITS)value)
                        ? BP_OK
                        : BP_ERR_OBJECT;
                case OBJECT_ANALOG_VALUE:
                    return Analog_Value_Units_Set(
                               instance, (BACNET_ENGINEERING_UNITS)value)
                        ? BP_OK
                        : BP_ERR_OBJECT;
                case OBJECT_INTEGER_VALUE:
                    return Integer_Value_Units_Set(
                               instance, (BACNET_ENGINEERING_UNITS)value)
                        ? BP_OK
                        : BP_ERR_OBJECT;
                default:
                    return BP_ERR_UNSUPPORTED;
            }
        case PROP_COV_INCREMENT:
            switch (object_type) {
                case OBJECT_ANALOG_INPUT:
                    Analog_Input_COV_Increment_Set(instance, (float)value);
                    return BP_OK;
                case OBJECT_ANALOG_OUTPUT:
                    Analog_Output_COV_Increment_Set(instance, (float)value);
                    return BP_OK;
                case OBJECT_ANALOG_VALUE:
                    Analog_Value_COV_Increment_Set(instance, (float)value);
                    return BP_OK;
                case OBJECT_INTEGER_VALUE:
                    Integer_Value_COV_Increment_Set(instance, (uint32_t)value);
                    return BP_OK;
                default:
                    return BP_ERR_UNSUPPORTED;
            }
        default:
            return BP_ERR_UNSUPPORTED;
    }
}

BP_API int32_t bacnet_plugin_object_set_state_texts(
    uint16_t object_type,
    uint32_t instance,
    const char *state_texts,
    uint32_t length)
{
    bool (*setter)(uint32_t, const char *) = NULL;
    char *previous = NULL;
    char *stored;
    uint64_t key;

    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!state_texts || length == 0) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    switch (object_type) {
        case OBJECT_MULTI_STATE_INPUT:
            setter = Multistate_Input_State_Text_List_Set;
            break;
        case OBJECT_MULTI_STATE_OUTPUT:
            setter = Multistate_Output_State_Text_List_Set;
            break;
        case OBJECT_MULTI_STATE_VALUE:
            setter = Multistate_Value_State_Text_List_Set;
            break;
        default:
            return BP_ERR_UNSUPPORTED;
    }
    key = bp_string_key(object_type, instance, 2);
    stored = bp_bytes_store(key, state_texts, length, &previous);
    if (!stored) {
        return BP_ERR_NO_MEMORY;
    }
    if (!setter(instance, stored)) {
        bp_string_entry_t *e = bp_string_slot(key, false);
        if (e) {
            e->value = previous;
        }
        free(stored);
        if (!previous) {
            bp_string_remove(key);
        }
        return BP_ERR_OBJECT;
    }
    /* the previous list is referenced until replaced: free it now */
    free(previous);
    return BP_OK;
}

BP_API int32_t bacnet_plugin_object_set_string(
    uint16_t object_type, uint32_t instance, const char *value)
{
    BACNET_CHARACTER_STRING text;

    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!value) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    if (object_type != OBJECT_CHARACTERSTRING_VALUE) {
        return BP_ERR_UNSUPPORTED;
    }
    if (!characterstring_init(&text, CHARACTER_UTF8, value, strlen(value))) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    return CharacterString_Value_Present_Value_Set(instance, &text)
        ? BP_OK
        : BP_ERR_OBJECT;
}

BP_API int32_t bacnet_plugin_object_set_present_values(
    const bp_present_value_update_t *updates, uint32_t count)
{
    uint32_t i;
    int32_t applied = 0;

    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (count > 0 && !updates) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    for (i = 0; i < count; i++) {
        if (bp_set_present_value(
                updates[i].object_type, updates[i].instance, updates[i].value,
                updates[i].priority) == BP_OK) {
            applied++;
        }
    }
    return applied;
}

BP_API int32_t bacnet_plugin_object_write(
    uint16_t object_type,
    uint32_t instance,
    uint32_t property,
    int32_t array_index,
    uint8_t priority,
    const uint8_t *data,
    uint16_t data_len,
    uint32_t *error_class,
    uint32_t *error_code)
{
    static BACNET_WRITE_PROPERTY_DATA wp_data;
    bool ok;

    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (data_len > sizeof(wp_data.application_data) || (data_len && !data)) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    memset(&wp_data, 0, sizeof(wp_data));
    wp_data.object_type = (BACNET_OBJECT_TYPE)object_type;
    wp_data.object_instance = instance;
    wp_data.object_property = (BACNET_PROPERTY_ID)property;
    wp_data.array_index =
        array_index < 0 ? BACNET_ARRAY_ALL : (BACNET_ARRAY_INDEX)array_index;
    wp_data.priority = (uint8_t)bp_priority(priority);
    if (data_len) {
        memcpy(wp_data.application_data, data, data_len);
    }
    wp_data.application_data_len = data_len;
    g.suppress_write_events = true;
    ok = Device_Write_Property(&wp_data);
    g.suppress_write_events = false;
    if (!ok) {
        if (error_class) {
            *error_class = (uint32_t)wp_data.error_class;
        }
        if (error_code) {
            *error_code = (uint32_t)wp_data.error_code;
        }
        return BP_ERR_OBJECT;
    }
    return BP_OK;
}

BP_API int32_t bacnet_plugin_object_read(
    uint16_t object_type,
    uint32_t instance,
    uint32_t property,
    int32_t array_index,
    uint8_t *buffer,
    uint16_t buffer_len,
    uint32_t *error_class,
    uint32_t *error_code)
{
    BACNET_READ_PROPERTY_DATA rp_data;
    int len;

    if (!g.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!buffer || buffer_len == 0) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    memset(&rp_data, 0, sizeof(rp_data));
    rp_data.object_type = (BACNET_OBJECT_TYPE)object_type;
    rp_data.object_instance = instance;
    rp_data.object_property = (BACNET_PROPERTY_ID)property;
    rp_data.array_index =
        array_index < 0 ? BACNET_ARRAY_ALL : (BACNET_ARRAY_INDEX)array_index;
    rp_data.application_data = buffer;
    rp_data.application_data_len = buffer_len;
    len = Device_Read_Property(&rp_data);
    if (len < 0) {
        if (error_class) {
            *error_class = (uint32_t)rp_data.error_class;
        }
        if (error_code) {
            *error_code = (uint32_t)rp_data.error_code;
        }
        return BP_ERR_OBJECT;
    }
    return len;
}
