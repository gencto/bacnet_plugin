/*
 * bacnet_plugin - state and helpers shared by the engine modules.
 *
 * Modules:
 *   bacnet_plugin.c  lifecycle, options, timers and the receive path
 *   bp_client.c      confirmed/unconfirmed requests, replies, bindings
 *   bp_server.c      local device, COV detection, object lifecycle
 *   bp_objects.c     local object properties, local Read/WriteProperty
 *   bp_events.c      event buffer drained by Dart
 *   bp_tables.c      device address table and string storage
 *   bp_io.c          wakeup socket, waiting for traffic, socket options
 *
 * Not part of the public API (see bacnet_plugin.h).
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef BP_INTERNAL_H
#define BP_INTERNAL_H

#if defined(_WIN32)
#include "bacport.h" /* winsock2 before windows.h */
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bacnet/bacaddr.h"
#include "bacnet/bacdef.h"
#include "bacnet/bacenum.h"
#include "bacnet/datalink/bip.h"
#include "bacnet/datalink/datalink.h"

#include "bacnet_plugin.h"

#if defined(__GNUC__) || defined(__clang__)
#define BP_PRINTF(fmt, first) \
    __attribute__((__format__(__printf__, fmt, first)))
#else
#define BP_PRINTF(fmt, first)
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

/* Slots of the string table per object. */
#define BP_STRING_NAME 0
#define BP_STRING_DESCRIPTION 1
#define BP_STRING_STATE_TEXTS 2
#define BP_STRING_DEVICE 3

/* ---- outstanding confirmed requests ----------------------------------- */

typedef struct {
    bool active;
    uint8_t service;
    uint32_t device_id;
    BACNET_ADDRESS dest;
} bp_transaction_t;

/* ---- engine state ------------------------------------------------------ */

typedef struct {
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
    int socket_buffer_size;
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
} bp_state_t;

/** The engine state (bacnet_plugin.c). */
extern bp_state_t bp_state;

/* ---- bp_events.c ------------------------------------------------------- */

void bp_event_init(bp_event_header_t *hdr, uint8_t kind);
void bp_event_src(bp_event_header_t *hdr, const BACNET_ADDRESS *src);
void bp_event_push(
    bp_event_header_t *hdr, const uint8_t *data, uint32_t data_len);
/** Queues a BP_EVENT_LOG event; level 0 debug .. 3 error. */
void bp_log(int level, const char *format, ...) BP_PRINTF(2, 3);

/* ---- bp_tables.c ------------------------------------------------------- */

bp_device_entry_t *bp_device_find(uint32_t device_id);
bp_device_entry_t *bp_device_put(
    uint32_t device_id, const BACNET_ADDRESS *address, uint16_t max_apdu);
void bp_device_remove(uint32_t device_id);

uint64_t bp_string_key(uint16_t type, uint32_t instance, uint8_t slot);
bp_string_entry_t *bp_string_slot(uint64_t key, bool insert);
/** Stores a copy of value and returns the stable pointer; the replaced
 *  value is returned in previous and must be freed by the caller. */
char *bp_string_store(uint64_t key, const char *value, char **previous);
/** Like bp_string_store() for a buffer that may contain NUL bytes. */
char *
bp_bytes_store(uint64_t key, const char *value, uint32_t len, char **previous);
void bp_string_remove(uint64_t key);
void bp_string_clear(void);

/* ---- bp_io.c ----------------------------------------------------------- */

bool bp_wake_init(void);
void bp_wake_drain(void);
/** Waits up to timeout_ms for traffic on the BACnet or wakeup sockets. */
void bp_wait(uint32_t timeout_ms);
#if defined(_WIN32)
void bp_apply_socket_buffer(int sock);
#endif

/* ---- bp_client.c ------------------------------------------------------- */

/** Transaction of invoke_id, or NULL when it is not one of ours. */
bp_transaction_t *bp_tx_for(uint8_t invoke_id);
void bp_register_client_handlers(void);

/* ---- bp_server.c ------------------------------------------------------- */

/** Runs the COV detection when the scan interval elapsed. */
void bp_cov_scan(uint32_t now);

#endif
