/*
 * bacnet_plugin - native engine around bacnet-stack.
 *
 * The engine owns the (process global, single threaded) bacnet-stack and
 * exposes a small, allocation free API to Dart:
 *
 *  - all calls except bacnet_plugin_wakeup() and bacnet_plugin_version()
 *    must be made from ONE thread / isolate at a time (the worker isolate);
 *  - confirmed requests are sent with pre-encoded service data and are
 *    identified by the returned invoke id;
 *  - everything the network produces (acks, errors, timeouts, I-Am, COV
 *    notifications, server side writes ...) is appended to an in-memory event
 *    buffer which Dart drains after each bacnet_plugin_poll() call. No
 *    callbacks cross the FFI boundary, which keeps the hot path cheap.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef BACNET_PLUGIN_H
#define BACNET_PLUGIN_H

#include <stdbool.h>
#include <stdint.h>

#if defined(_WIN32)
#define BP_API __declspec(dllexport)
#else
#define BP_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Result codes (negative values) ---------------------------------- */
#define BP_OK 0
#define BP_ERR_NOT_INITIALIZED (-1)
#define BP_ERR_ALREADY_INITIALIZED (-2)
#define BP_ERR_INVALID_ARGUMENT (-3)
#define BP_ERR_DATALINK (-4)
#define BP_ERR_NOT_BOUND (-5)
#define BP_ERR_NO_TRANSACTION (-6)
#define BP_ERR_APDU_TOO_LARGE (-7)
#define BP_ERR_SEND_FAILED (-8)
#define BP_ERR_COMMUNICATION_DISABLED (-9)
#define BP_ERR_OBJECT (-10)
#define BP_ERR_NO_MEMORY (-11)
#define BP_ERR_UNSUPPORTED (-12)
#define BP_ERR_SERVER_DISABLED (-13)

/* ---- Event kinds ------------------------------------------------------ */
/** Complex ACK for one of our confirmed requests. data = service ACK data */
#define BP_EVENT_COMPLEX_ACK 1
/** Simple ACK for one of our confirmed requests. */
#define BP_EVENT_SIMPLE_ACK 2
/** Error PDU. a = error class, b = error code. If flags & BP_FLAG_COMPLEX
 *  the class/code are not decoded and data holds the raw error payload. */
#define BP_EVENT_ERROR 3
/** Reject PDU. a = reject reason */
#define BP_EVENT_REJECT 4
/** Abort PDU. a = abort reason, flags & BP_FLAG_LOCAL when generated
 *  locally (e.g. segmented replies are not supported). */
#define BP_EVENT_ABORT 5
/** No answer after all APDU retries. */
#define BP_EVENT_TIMEOUT 6
/** Unconfirmed service request received (I-Am, COV notification, ...).
 *  For I-Am: device_id, a = max APDU, b = vendor id, c = segmentation. */
#define BP_EVENT_UNCONFIRMED 7
/** Confirmed notification received and already acknowledged (COV). */
#define BP_EVENT_CONFIRMED_NOTIFICATION 8
/** A remote client wrote to one of our server objects.
 *  a = object type, b = instance, c = property, d = array index,
 *  priority = write priority, data = application encoded value. */
#define BP_EVENT_WRITE 9
/** Diagnostic message, data = UTF-8 text, a = level (0 debug .. 3 error) */
#define BP_EVENT_LOG 10

#define BP_FLAG_ABORT_FROM_SERVER 0x01
#define BP_FLAG_COMPLEX 0x02
#define BP_FLAG_LOCAL 0x04
/** The complex ACK was received in segments. */
#define BP_FLAG_SEGMENTED 0x08

#define BP_DEVICE_UNKNOWN 0xFFFFFFFFu

/**
 * Header that precedes every event in the event buffer (host byte order,
 * 48 bytes, no padding). `data_len` bytes of payload follow the header.
 */
typedef struct {
    uint8_t kind;
    uint8_t service;
    uint8_t invoke_id;
    uint8_t flags;
    uint32_t device_id;
    uint32_t a;
    uint32_t b;
    uint32_t c;
    int32_t d;
    uint8_t priority;
    uint8_t src_mac_len;
    uint16_t src_net;
    uint8_t src_mac[7];
    uint8_t src_len;
    uint8_t src_adr[7];
    uint8_t reserved0;
    uint16_t data_len;
    uint16_t reserved1;
} bp_event_header_t;

/** Batched present value update for server objects. */
typedef struct {
    uint32_t instance;
    uint16_t object_type;
    uint8_t priority;
    uint8_t reserved;
    double value;
} bp_present_value_update_t;

/** Engine statistics. */
typedef struct {
    uint64_t packets_received;
    uint64_t requests_sent;
    uint64_t replies_dropped;
    uint64_t events_dropped;
    uint64_t timeouts;
    uint64_t poll_calls;
    uint32_t tsm_idle;
    uint32_t bound_devices;
    uint32_t event_buffer_capacity;
    /** Complex ACKs received in segments and reassembled. */
    uint32_t segmented_replies;
} bp_stats_t;

/* ---- Tunable options for bacnet_plugin_set_option() ------------------- */
/** Drop replies whose source does not match the request destination. */
#define BP_OPTION_STRICT_SOURCE 1
/** Interval of the server COV detection scan in milliseconds. */
#define BP_OPTION_COV_SCAN_INTERVAL_MS 2
/** Upper bound of the event buffer in bytes. */
#define BP_OPTION_MAX_EVENT_BUFFER 3
/** APDU timeout in milliseconds. */
#define BP_OPTION_APDU_TIMEOUT_MS 4
/** Number of APDU retries. */
#define BP_OPTION_APDU_RETRIES 5
/** Maximum number of TSM steps of the server COV scan per poll call. */
#define BP_OPTION_COV_SCAN_BUDGET 6
/** Segments accepted in answers to our requests (0..32, below 2 disables
 *  segmented responses). */
#define BP_OPTION_MAX_SEGMENTS 7

/* ---- Lifecycle -------------------------------------------------------- */

/** Version string of the engine and the bundled bacnet-stack. */
BP_API const char *bacnet_plugin_version(void);

/**
 * Initializes the BACnet/IP datalink and the stack.
 *
 * @param iface interface name ("eth0"), IPv4 address ("192.168.1.10") or NULL
 *        for the default interface.
 * @param port UDP port (47808 by default).
 * @param device_instance own Device object instance.
 * @param socket_buffer_bytes SO_RCVBUF / SO_SNDBUF size, 0 keeps OS default.
 * @return BP_OK or a negative BP_ERR_* code.
 */
BP_API int32_t bacnet_plugin_init(
    const char *iface,
    uint16_t port,
    uint32_t device_instance,
    int32_t socket_buffer_bytes);

/** Closes sockets and resets the engine state. */
BP_API void bacnet_plugin_shutdown(void);

/** Sets a tunable (BP_OPTION_*). Returns BP_OK or BP_ERR_INVALID_ARGUMENT. */
BP_API int32_t bacnet_plugin_set_option(int32_t option, int64_t value);

/**
 * Waits up to timeout_ms for network traffic (or a wakeup), processes up to
 * max_packets packets and runs all stack timers.
 * @return number of processed packets or a negative error code.
 */
BP_API int32_t bacnet_plugin_poll(uint32_t timeout_ms, uint32_t max_packets);

/** Interrupts a blocking bacnet_plugin_poll(). Safe from any thread. */
BP_API void bacnet_plugin_wakeup(void);

/** Pointer to the event buffer. Valid until the next engine call. */
BP_API const uint8_t *bacnet_plugin_events_data(void);
/** Number of bytes in the event buffer. */
BP_API uint32_t bacnet_plugin_events_length(void);
/** Empties the event buffer. */
BP_API void bacnet_plugin_events_clear(void);

/** Fills `out` with engine statistics. */
BP_API void bacnet_plugin_stats(bp_stats_t *out);

/* ---- Client ----------------------------------------------------------- */

/**
 * Sends a confirmed request to a bound device.
 * @param service confirmed service choice.
 * @param data encoded service request (without APDU header).
 * @return invoke id (1..255) or a negative BP_ERR_* code.
 */
BP_API int32_t bacnet_plugin_send_confirmed(
    uint32_t device_id,
    uint8_t service,
    const uint8_t *data,
    uint16_t data_len,
    uint8_t priority);

/**
 * Sends an unconfirmed request.
 * @param device_id target device or BP_DEVICE_UNKNOWN for a broadcast.
 * @param network broadcast network: 0 = local, 0xFFFF = global, else remote.
 */
BP_API int32_t bacnet_plugin_send_unconfirmed(
    uint32_t device_id,
    uint16_t network,
    uint8_t service,
    const uint8_t *data,
    uint16_t data_len);

/**
 * Adds or replaces a static device address binding.
 * @param host IPv4 address or host name of the device (or of the router).
 * @param net remote network number (0 for local devices).
 * @param adr remote MAC address behind the router (NULL for local).
 */
BP_API int32_t bacnet_plugin_bind_device(
    uint32_t device_id,
    const char *host,
    uint16_t port,
    uint16_t net,
    const uint8_t *adr,
    uint8_t adr_len,
    uint16_t max_apdu);

/** Removes the address binding of a device. */
BP_API void bacnet_plugin_unbind_device(uint32_t device_id);

/**
 * Returns 1 and fills the optional outputs when the device is bound,
 * 0 otherwise. `mac` must hold at least 7 bytes.
 */
BP_API int32_t bacnet_plugin_device_binding(
    uint32_t device_id,
    uint8_t *mac,
    uint8_t *mac_len,
    uint16_t *net,
    uint16_t *max_apdu);

/**
 * Copies the own BACnet/IP address (IPv4 address and UDP port, 6 bytes) to
 * `mac`, which must hold at least 6 bytes: where devices send
 * notifications to this engine.
 * @return the number of bytes copied or a negative BP_ERR_* code.
 */
BP_API int32_t bacnet_plugin_local_address(uint8_t *mac);

/** Registers as foreign device with a BBMD and keeps the registration. */
BP_API int32_t bacnet_plugin_register_foreign_device(
    const char *host, uint16_t port, uint16_t ttl_seconds);

/* ---- Server ----------------------------------------------------------- */

/**
 * Turns the local Device object into a BACnet server: registers the server
 * service handlers (Who-Is, Read/WriteProperty(Multiple), SubscribeCOV,
 * ReadRange, DCC, ...) and sends an I-Am.
 */
BP_API int32_t
bacnet_plugin_server_enable(uint32_t device_instance, const char *device_name);

/** Sets a string property of the local Device object
 *  (vendor name, model name, description, location, firmware, version). */
BP_API int32_t
bacnet_plugin_device_set_string(uint32_t property, const char *value);

/** Sets the vendor identifier of the local Device object. */
BP_API int32_t bacnet_plugin_device_set_vendor_id(uint16_t vendor_id);

/** Broadcasts an I-Am for the local device. */
BP_API int32_t bacnet_plugin_send_i_am(void);

/** Creates a server object. Returns the instance or a negative error. */
BP_API int64_t bacnet_plugin_object_create(
    uint16_t object_type,
    uint32_t instance,
    uint32_t *error_class,
    uint32_t *error_code);

/** Deletes a server object. */
BP_API int32_t
bacnet_plugin_object_delete(uint16_t object_type, uint32_t instance);

/** Sets the object name (UTF-8, copied). */
BP_API int32_t bacnet_plugin_object_set_name(
    uint16_t object_type, uint32_t instance, const char *name);

/** Sets the object description (UTF-8, copied). */
BP_API int32_t bacnet_plugin_object_set_description(
    uint16_t object_type, uint32_t instance, const char *description);

/**
 * Sets a numeric property locally (no network write semantics):
 * present-value (85), out-of-service (81), units (117), cov-increment (22).
 * A NaN present value relinquishes the given priority of commandable objects.
 */
BP_API int32_t bacnet_plugin_object_set_number(
    uint16_t object_type,
    uint32_t instance,
    uint32_t property,
    double value,
    uint8_t priority);

/** Sets the state texts of a multi-state object: NUL separated strings
 *  (e.g. "Off\0On\0Auto\0"); defines the number of states. */
BP_API int32_t bacnet_plugin_object_set_state_texts(
    uint16_t object_type,
    uint32_t instance,
    const char *state_texts,
    uint32_t length);

/** Sets the present value of a CharacterString Value object. */
BP_API int32_t bacnet_plugin_object_set_string(
    uint16_t object_type, uint32_t instance, const char *value);

/** Applies many present value updates at once.
 *  @return number of successfully applied updates. */
BP_API int32_t bacnet_plugin_object_set_present_values(
    const bp_present_value_update_t *updates, uint32_t count);

/** Writes an application encoded value using WriteProperty semantics. */
BP_API int32_t bacnet_plugin_object_write(
    uint16_t object_type,
    uint32_t instance,
    uint32_t property,
    int32_t array_index,
    uint8_t priority,
    const uint8_t *data,
    uint16_t data_len,
    uint32_t *error_class,
    uint32_t *error_code);

/** Reads a property of a server object as application encoded data.
 *  @return encoded length or a negative error code. */
BP_API int32_t bacnet_plugin_object_read(
    uint16_t object_type,
    uint32_t instance,
    uint32_t property,
    int32_t array_index,
    uint8_t *buffer,
    uint16_t buffer_len,
    uint32_t *error_class,
    uint32_t *error_code);

#ifdef __cplusplus
}
#endif

#endif
