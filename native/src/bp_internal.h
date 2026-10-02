/*
 * bacnet_plugin - state and helpers shared by the engine modules.
 *
 * Modules:
 *   bacnet_plugin.c  lifecycle, options, timers and the receive path
 *   bp_client.c      confirmed/unconfirmed requests, replies, bindings
 *   bp_server.c      local device, COV detection, object lifecycle
 *   bp_objects.c     local object properties, local Read/WriteProperty
 *   bp_segments.c    reception of segmented answers
 *   bp_events.c      event buffer drained by Dart
 *   bp_tables.c      device address table and string storage
 *   bp_nc.c          Notification Class objects created by the application
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

/* Segments accepted per answer unless BP_OPTION_MAX_SEGMENTS says otherwise
   (32 segments of 1476 bytes fit into one event). */
#define BP_DEFAULT_MAX_SEGMENTS 32

/* Slots of the string table per object. */
#define BP_STRING_NAME 0
#define BP_STRING_DESCRIPTION 1
#define BP_STRING_STATE_TEXTS 2
#define BP_STRING_DEVICE 3
#define BP_STRING_PASSWORD 4
#define BP_STRING_FILE_TYPE 5

/* ---- outstanding confirmed requests ----------------------------------- */

/** Reassembly of a segmented ComplexACK (bp_segments.c). */
typedef struct bp_segments bp_segments_t;

typedef struct {
    bool active;
    uint8_t service;
    uint32_t device_id;
    BACNET_ADDRESS dest;
    /* set while the answer arrives in segments */
    bp_segments_t *segments;
} bp_transaction_t;

/* ---- engine state ------------------------------------------------------ */

typedef struct {
    bool initialized;
    bool server_enabled;
    bool strict_source;
    bool suppress_write_events;
    /* set while an object of the server writes another one */
    bool internal_write;
    uint32_t last_ms;
    uint32_t second_acc;
    uint32_t object_acc;
    uint32_t nc_rescan_elapsed;
    bool nc_rescan;
    uint32_t cov_scan_last;
    uint32_t cov_scan_interval_ms;
    uint32_t cov_scan_budget;
    int socket_buffer_size;
    /* segmentation: segments accepted per answer, last invoke id we used,
       transactions receiving segments */
    uint8_t max_segments;
    uint8_t last_invoke_id;
    uint32_t segmenting;
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
/** Handles a received NPDU (after the BVLC header) from src. */
void bp_receive_packet(BACNET_ADDRESS *src, uint8_t *pdu, uint16_t len);
/** Queues a BP_EVENT_UNCONFIRMED event for a received request. */
void bp_forward_unconfirmed(
    uint8_t service,
    uint8_t *service_request,
    uint16_t service_len,
    BACNET_ADDRESS *src);
#include "bacnet/npdu.h"
/** Queues a BP_EVENT_NETWORK event for a received network layer message. */
void bp_network_received(
    const BACNET_ADDRESS *src,
    const BACNET_ADDRESS *dest,
    const BACNET_NPDU_DATA *npdu_data,
    const uint8_t *message,
    uint16_t message_len);

/* ---- bp_segments.c ----------------------------------------------------- */

/** Handles a segmented ComplexACK (APDU without NPDU) from src. */
void bp_segment_received(
    const BACNET_ADDRESS *src, const uint8_t *apdu, uint16_t apdu_len);
/** Times out transactions whose segments stopped arriving. */
void bp_segments_timer(uint32_t now);
/** Ends a transaction and releases its reassembly buffer. */
void bp_tx_end(bp_transaction_t *tx);

/* ---- bp_server.c ------------------------------------------------------- */

/** Runs the COV detection when the scan interval elapsed. */
void bp_cov_scan(uint32_t now);
void bp_event_reporting(uint32_t seconds);
void bp_alarm_ack_hooks(void);
#include "bacnet/list_element.h"
/* reports a successful Add/RemoveListElement of a remote client */
void bp_list_element_changed(
    uint8_t service, const BACNET_LIST_ELEMENT_DATA *list_element);
/** PDU type (PDU_TYPE_*) of the answer the last handler put into
 *  Handler_Transmit_Buffer, 0xFF if none. */
uint8_t bp_reply_pdu_type(void);
/** Queues a BP_EVENT_SERVICE event for a request of src that changed the
 *  server. */
void bp_service_reported(
    uint8_t service,
    const uint8_t *request,
    int request_len,
    const BACNET_ADDRESS *src);

/* ---- Schedules and internal writes (bp_schedule.c) -------------------- */

#include "bacnet/rp.h"
#include "bacnet/wp.h"
void bp_internal_writes_init(void);
bool bp_schedule_priority_set(uint32_t instance, uint8_t priority);
int bp_schedule_read_property(BACNET_READ_PROPERTY_DATA *rpdata);
bool bp_schedule_write_property(BACNET_WRITE_PROPERTY_DATA *wp_data);
void bp_schedule_timer(uint32_t object_instance, uint16_t milliseconds);
bool bp_schedule_delete(uint32_t object_instance);
bool bp_calendar_write_property(BACNET_WRITE_PROPERTY_DATA *wp_data);

/* ---- backup and restore (bp_backup.c) --------------------------------- */

#include "bacnet/apdu.h"

/** Handles the backup and restore states of a ReinitializeDevice request;
 *  false when bacnet-stack answers it. */
bool bp_backup_reinitialize(
    uint8_t *request,
    uint16_t len,
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_DATA *service_data);
void bp_backup_activity(void);
void bp_backup_timer(uint32_t seconds);
void bp_backup_reset(void);
int bp_device_read_property(BACNET_READ_PROPERTY_DATA *rpdata);
void bp_device_property_lists(
    const int32_t **required,
    const int32_t **optional,
    const int32_t **proprietary);

/* ---- Trend Log objects (bp_trendlog.c) -------------------------------- */

#include "bacnet/readrange.h"
void bp_tl_init(void);
unsigned bp_tl_count(void);
uint32_t bp_tl_index_to_instance(unsigned index);
bool bp_tl_valid_instance(uint32_t instance);
bool bp_tl_object_name(uint32_t instance, BACNET_CHARACTER_STRING *name);
bool bp_tl_text_set(uint32_t instance, const char *text);
int bp_tl_read_property(BACNET_READ_PROPERTY_DATA *rpdata);
bool bp_tl_write_property(BACNET_WRITE_PROPERTY_DATA *wp_data);
void bp_tl_property_lists(
    const int32_t **required,
    const int32_t **optional,
    const int32_t **proprietary);
void bp_tl_writable_property_list(uint32_t instance, const int32_t **properties);
bool bp_tl_rr_info(BACNET_READ_RANGE_DATA *request, RR_PROP_INFO *info);
uint32_t bp_tl_create(uint32_t object_instance);
bool bp_tl_delete(uint32_t object_instance);
void bp_tl_timer(uint32_t instance, uint16_t milliseconds);

/* ---- File objects with the content in memory (bp_files.c) ------------ */

#include "bacnet/rp.h"
#include "bacnet/wp.h"
#include "bacnet/apdu.h"
void bp_files_init(void);
uint32_t bp_file_create(uint32_t object_instance);
bool bp_file_delete(uint32_t object_instance);
int bp_file_read_property(BACNET_READ_PROPERTY_DATA *rpdata);
bool bp_file_write_property(BACNET_WRITE_PROPERTY_DATA *wp_data);
bool bp_file_description_set(uint32_t instance, const char *description);
void bp_on_atomic_write_file(
    uint8_t *request,
    uint16_t len,
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_DATA *service_data);

/* ---- Notification Class objects of the application (bp_nc.c) ---------- */

#if defined(INTRINSIC_REPORTING)
#include "bacnet/bacstr.h"
#include "bacnet/rp.h"
void bp_nc_init(void);
unsigned bp_nc_count(void);
uint32_t bp_nc_index_to_instance(unsigned index);
bool bp_nc_valid_instance(uint32_t instance);
bool bp_nc_object_name(uint32_t instance, BACNET_CHARACTER_STRING *name);
bool bp_nc_name_set(uint32_t instance, const char *name);
bool bp_nc_description_set(uint32_t instance, const char *description);
int bp_nc_read_property(BACNET_READ_PROPERTY_DATA *rpdata);
uint32_t bp_nc_create(uint32_t instance);
bool bp_nc_delete(uint32_t instance);
int bp_nc_add_list_element(BACNET_LIST_ELEMENT_DATA *list_element);
int bp_nc_remove_list_element(BACNET_LIST_ELEMENT_DATA *list_element);
#endif

#endif
