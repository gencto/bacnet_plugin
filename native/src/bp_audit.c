/*
 * BACnet auditing (ASHRAE 135-2016bi): the Audit Log object, an Audit Reporter
 * object, and the AuditNotification and AuditLogQuery services.
 *
 * bacnet-stack ships the Audit Log object (auditlog.c) and the record codec
 * (bacaudit.c) but no Audit Reporter object and no AuditNotification or
 * AuditLogQuery service handlers. This module adds:
 *   - the ReadRange glue for the Audit Log (its RR_Info slot is NULL),
 *   - a fully custom Audit Reporter object (like bp_event_enrollment.c),
 *   - auto-generation of audit records for write operations, inserted into a
 *     configured Audit Log and/or sent as AuditNotification to a recipient,
 *   - the server side of AuditLogQuery.
 * The client side (receiving AuditNotification) is wired in bp_client.c.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>
#include <string.h>

#include "bacnet_plugin.h"
#include "bacnet/abort.h"
#include "bacnet/apdu.h"
#include "bacnet/bacaudit.h"
#include "bacnet/bacdcode.h"
#include "bacnet/bacerror.h"
#include "bacnet/bacdest.h"
#include "bacnet/datalink/datalink.h"
#include "bacnet/datetime.h"
#include "bacnet/npdu.h"
#include "bacnet/basic/object/auditlog.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/tsm/tsm.h"
#include "bp_internal.h"

#ifndef BP_AR_MAX
#define BP_AR_MAX 4u
#endif

/* ---- the source of the operation in progress --------------------------- */

/* Set by the receive path before a request is dispatched, so the Audit
   Reporter can attribute an operation to the client that initiated it. */
static BACNET_ADDRESS bp_audit_src;
static bool bp_audit_src_valid;

void bp_audit_set_source(const BACNET_ADDRESS *src)
{
    if (src) {
        bp_audit_src = *src;
        bp_audit_src_valid = true;
    } else {
        bp_audit_src_valid = false;
    }
}

/* ---- Audit Log ReadRange glue ------------------------------------------ */

bool bp_al_rr_info(BACNET_READ_RANGE_DATA *request, RR_PROP_INFO *info)
{
    if (!request || !info) {
        return false;
    }
    if (!Audit_Log_Valid_Instance(request->object_instance)) {
        request->error_class = ERROR_CLASS_OBJECT;
        request->error_code = ERROR_CODE_UNKNOWN_OBJECT;
        return false;
    }
    if (request->object_property != PROP_LOG_BUFFER) {
        request->error_class = ERROR_CLASS_SERVICES;
        request->error_code = ERROR_CODE_PROPERTY_IS_NOT_A_LIST;
        return false;
    }
    if (request->array_index != BACNET_ARRAY_ALL) {
        request->error_class = ERROR_CLASS_PROPERTY;
        request->error_code = ERROR_CODE_PROPERTY_IS_NOT_AN_ARRAY;
        return false;
    }
    info->RequestTypes = RR_BY_POSITION | RR_BY_SEQUENCE | RR_BY_TIME;
    info->Handler = Audit_Log_Read_Range;
    return true;
}

BP_API int32_t
bacnet_plugin_audit_log_configure(uint32_t instance, int32_t enabled)
{
    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!Audit_Log_Valid_Instance(instance)) {
        return BP_ERR_OBJECT;
    }
    if (enabled >= 0) {
        (void)Audit_Log_Enable_Set(instance, enabled != 0);
    }
    return BP_OK;
}

/* ---- Audit Reporter object --------------------------------------------- */

typedef struct {
    bool used;
    const char *name;
    const char *description;
    uint8_t audit_level; /* BACNET_AUDIT_LEVEL */
    uint32_t operations; /* bit mask over BACNET_AUDIT_OPERATION 0..31 */
    uint32_t audit_log; /* Audit Log instance, BACNET_MAX_INSTANCE = none */
    uint32_t max_send_delay; /* seconds (stored only) */
    bool has_recipient;
    BACNET_RECIPIENT recipient;
} bp_ar_t;

static bp_ar_t bp_ar[BP_AR_MAX];

static const int32_t bp_ar_required[] = { PROP_OBJECT_IDENTIFIER,
                                          PROP_OBJECT_NAME,
                                          PROP_OBJECT_TYPE,
                                          PROP_STATUS_FLAGS,
                                          PROP_RELIABILITY,
                                          PROP_AUDIT_LEVEL,
                                          PROP_AUDIT_NOTIFICATION_RECIPIENT,
                                          PROP_AUDITABLE_OPERATIONS,
                                          PROP_MAXIMUM_SEND_DELAY,
                                          -1 };
static const int32_t bp_ar_optional[] = { PROP_DESCRIPTION, -1 };
static const int32_t bp_ar_proprietary[] = { -1 };

void bp_ar_init(void)
{
    memset(bp_ar, 0, sizeof(bp_ar));
}

bool bp_ar_valid_instance(uint32_t instance)
{
    return instance < BP_AR_MAX && bp_ar[instance].used;
}

unsigned bp_ar_count(void)
{
    unsigned count = 0;
    unsigned i;

    for (i = 0; i < BP_AR_MAX; i++) {
        if (bp_ar[i].used) {
            count++;
        }
    }
    return count;
}

uint32_t bp_ar_index_to_instance(unsigned index)
{
    unsigned i;

    for (i = 0; i < BP_AR_MAX; i++) {
        if (bp_ar[i].used) {
            if (index == 0) {
                return i;
            }
            index--;
        }
    }
    return BP_AR_MAX;
}

bool bp_ar_object_name(uint32_t instance, BACNET_CHARACTER_STRING *name)
{
    char buffer[32];

    if (!bp_ar_valid_instance(instance)) {
        return false;
    }
    if (bp_ar[instance].name) {
        return characterstring_init_ansi(name, bp_ar[instance].name);
    }
    snprintf(buffer, sizeof(buffer), "AR-%lu", (unsigned long)instance);
    return characterstring_init_ansi(name, buffer);
}

bool bp_ar_name_set(uint32_t instance, const char *name)
{
    if (!bp_ar_valid_instance(instance)) {
        return false;
    }
    bp_ar[instance].name = name;
    return true;
}

bool bp_ar_description_set(uint32_t instance, const char *description)
{
    if (!bp_ar_valid_instance(instance)) {
        return false;
    }
    bp_ar[instance].description = description;
    return true;
}

void bp_ar_property_lists(
    const int32_t **required,
    const int32_t **optional,
    const int32_t **proprietary)
{
    if (required) {
        *required = bp_ar_required;
    }
    if (optional) {
        *optional = bp_ar_optional;
    }
    if (proprietary) {
        *proprietary = bp_ar_proprietary;
    }
}

int bp_ar_read_property(BACNET_READ_PROPERTY_DATA *rpdata)
{
    bp_ar_t *object;
    uint8_t *apdu;
    BACNET_CHARACTER_STRING text;
    BACNET_BIT_STRING bits;
    int len = 0;
    unsigned i;

    if (!rpdata || !rpdata->application_data ||
        rpdata->application_data_len <= 0) {
        return 0;
    }
    if (!bp_ar_valid_instance(rpdata->object_instance)) {
        rpdata->error_class = ERROR_CLASS_OBJECT;
        rpdata->error_code = ERROR_CODE_UNKNOWN_OBJECT;
        return BACNET_STATUS_ERROR;
    }
    object = &bp_ar[rpdata->object_instance];
    apdu = rpdata->application_data;
    switch (rpdata->object_property) {
        case PROP_OBJECT_IDENTIFIER:
            len = encode_application_object_id(
                apdu, OBJECT_AUDIT_REPORTER, rpdata->object_instance);
            break;
        case PROP_OBJECT_NAME:
            bp_ar_object_name(rpdata->object_instance, &text);
            len = encode_application_character_string(apdu, &text);
            break;
        case PROP_DESCRIPTION:
            characterstring_init_ansi(
                &text, object->description ? object->description : "");
            len = encode_application_character_string(apdu, &text);
            break;
        case PROP_OBJECT_TYPE:
            len = encode_application_enumerated(apdu, OBJECT_AUDIT_REPORTER);
            break;
        case PROP_STATUS_FLAGS:
            bitstring_init(&bits);
            bitstring_set_bit(&bits, STATUS_FLAG_IN_ALARM, false);
            bitstring_set_bit(&bits, STATUS_FLAG_FAULT, false);
            bitstring_set_bit(&bits, STATUS_FLAG_OVERRIDDEN, false);
            bitstring_set_bit(&bits, STATUS_FLAG_OUT_OF_SERVICE, false);
            len = encode_application_bitstring(apdu, &bits);
            break;
        case PROP_RELIABILITY:
            len = encode_application_enumerated(
                apdu, RELIABILITY_NO_FAULT_DETECTED);
            break;
        case PROP_AUDIT_LEVEL:
            len = encode_application_enumerated(apdu, object->audit_level);
            break;
        case PROP_AUDIT_NOTIFICATION_RECIPIENT:
            if (object->has_recipient) {
                len = bacnet_recipient_encode(apdu, &object->recipient);
            } else {
                BACNET_RECIPIENT none;
                none.tag = 0;
                none.type.device.type = OBJECT_DEVICE;
                none.type.device.instance = BACNET_MAX_INSTANCE;
                len = bacnet_recipient_encode(apdu, &none);
            }
            break;
        case PROP_AUDITABLE_OPERATIONS:
            bitstring_init(&bits);
            bitstring_set_bits_used(&bits, 2, 0);
            for (i = 0; i < 16; i++) {
                bitstring_set_bit(
                    &bits, (uint8_t)i, (object->operations >> i) & 1u);
            }
            len = encode_application_bitstring(apdu, &bits);
            break;
        case PROP_MAXIMUM_SEND_DELAY:
            len = encode_application_unsigned(apdu, object->max_send_delay);
            break;
        default:
            rpdata->error_class = ERROR_CLASS_PROPERTY;
            rpdata->error_code = ERROR_CODE_UNKNOWN_PROPERTY;
            return BACNET_STATUS_ERROR;
    }
    return len;
}

bool bp_ar_write_property(BACNET_WRITE_PROPERTY_DATA *wp_data)
{
    if (wp_data) {
        wp_data->error_class = ERROR_CLASS_PROPERTY;
        wp_data->error_code = ERROR_CODE_WRITE_ACCESS_DENIED;
    }
    return false;
}

uint32_t bp_ar_create(uint32_t instance)
{
    unsigned i;

    if (instance == BACNET_MAX_INSTANCE) {
        for (i = 0; i < BP_AR_MAX; i++) {
            if (!bp_ar[i].used) {
                instance = i;
                break;
            }
        }
    }
    if (instance >= BP_AR_MAX) {
        return BACNET_MAX_INSTANCE;
    }
    if (!bp_ar[instance].used) {
        memset(&bp_ar[instance], 0, sizeof(bp_ar[instance]));
        bp_ar[instance].used = true;
        bp_ar[instance].audit_level = AUDIT_LEVEL_NONE;
        bp_ar[instance].audit_log = BACNET_MAX_INSTANCE;
    }
    return instance;
}

bool bp_ar_delete(uint32_t instance)
{
    if (!bp_ar_valid_instance(instance)) {
        return false;
    }
    bp_ar[instance].used = false;
    return true;
}

BP_API int32_t bacnet_plugin_audit_reporter_configure(
    uint32_t instance,
    uint8_t audit_level,
    uint32_t operations_mask,
    uint32_t audit_log_instance,
    uint32_t max_send_delay)
{
    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!bp_ar_valid_instance(instance)) {
        return BP_ERR_OBJECT;
    }
    bp_ar[instance].audit_level = audit_level;
    bp_ar[instance].operations = operations_mask;
    bp_ar[instance].audit_log = audit_log_instance;
    bp_ar[instance].max_send_delay = max_send_delay;
    return BP_OK;
}

BP_API int32_t bacnet_plugin_audit_reporter_set_recipient(
    uint32_t instance,
    uint32_t device_id,
    const uint8_t *mac,
    uint8_t mac_len,
    uint16_t net,
    const uint8_t *adr,
    uint8_t adr_len)
{
    bp_ar_t *object;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!bp_ar_valid_instance(instance)) {
        return BP_ERR_OBJECT;
    }
    if ((mac_len > 0 && !mac) || (adr_len > 0 && !adr) ||
        mac_len > MAX_MAC_LEN || adr_len > MAX_MAC_LEN ||
        (adr_len > 0 && net == 0)) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    object = &bp_ar[instance];
    memset(&object->recipient, 0, sizeof(object->recipient));
    if (device_id) {
        object->recipient.tag = 0; /* device */
        object->recipient.type.device.type = OBJECT_DEVICE;
        object->recipient.type.device.instance = device_id;
        object->has_recipient = true;
    } else if (mac_len > 0) {
        object->recipient.tag = 1; /* address */
        object->recipient.type.address.mac_len = mac_len;
        memcpy(object->recipient.type.address.mac, mac, mac_len);
        object->recipient.type.address.net = net;
        object->recipient.type.address.len = adr_len;
        if (adr_len) {
            memcpy(object->recipient.type.address.adr, adr, adr_len);
        }
        object->has_recipient = true;
    } else {
        object->has_recipient = false;
    }
    return BP_OK;
}

/* ---- AuditNotification send -------------------------------------------- */

/* Resolves a recipient to a destination address. Returns false when a device
   recipient is not bound yet. */
static bool
bp_audit_resolve(const BACNET_RECIPIENT *recipient, BACNET_ADDRESS *dest)
{
    if (recipient->tag == 0) {
        bp_device_entry_t *device =
            bp_device_find(recipient->type.device.instance);
        if (!device || device->address.mac_len == 0) {
            return false;
        }
        *dest = device->address;
        return true;
    }
    *dest = recipient->type.address;
    return true;
}

/* Sends one BACnetAuditNotification as an UnconfirmedAuditNotification to the
   destination. The service body is the notification wrapped in context tag 0.
 */
static void bp_audit_send(
    const BACNET_ADDRESS *dest, const BACNET_AUDIT_NOTIFICATION *notification)
{
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    uint8_t *buf = &bp_state.tx_buf[0];
    int pdu_len;

    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(&npdu_data, false, MESSAGE_PRIORITY_NORMAL);
    pdu_len =
        npdu_encode_pdu(buf, (BACNET_ADDRESS *)dest, &my_address, &npdu_data);
    buf[pdu_len++] = PDU_TYPE_UNCONFIRMED_SERVICE_REQUEST;
    buf[pdu_len++] = SERVICE_UNCONFIRMED_AUDIT_NOTIFICATION;
    pdu_len += encode_opening_tag(&buf[pdu_len], 0);
    pdu_len +=
        bacnet_audit_log_notification_encode(&buf[pdu_len], notification);
    pdu_len += encode_closing_tag(&buf[pdu_len], 0);
    (void)datalink_send_pdu((BACNET_ADDRESS *)dest, &npdu_data, buf, pdu_len);
}

/* ---- auto-generation --------------------------------------------------- */

/* Builds and reports an audit record for one operation on this device. */
static void bp_audit_report(
    uint8_t operation,
    BACNET_OBJECT_TYPE object_type,
    uint32_t object_instance,
    uint32_t property_id)
{
    BACNET_AUDIT_NOTIFICATION notification;
    BACNET_ADDRESS dest;
    unsigned i;

    for (i = 0; i < BP_AR_MAX; i++) {
        bp_ar_t *reporter = &bp_ar[i];

        if (!reporter->used || reporter->audit_level == AUDIT_LEVEL_NONE) {
            continue;
        }
        if (operation < 32 && !((reporter->operations >> operation) & 1u)) {
            continue;
        }
        memset(&notification, 0, sizeof(notification));
        Device_getCurrentDateTime(
            &notification.source_timestamp.value.dateTime);
        notification.source_timestamp.tag = TIME_STAMP_DATETIME;
        /* source-device: the initiator (an address), else this device */
        if (bp_audit_src_valid) {
            notification.source_device.tag = 1;
            notification.source_device.type.address = bp_audit_src;
        } else {
            notification.source_device.tag = 0;
            notification.source_device.type.device.type = OBJECT_DEVICE;
            notification.source_device.type.device.instance =
                Device_Object_Instance_Number();
        }
        notification.operation = operation;
        /* target-device: this device */
        notification.target_device.tag = 0;
        notification.target_device.type.device.type = OBJECT_DEVICE;
        notification.target_device.type.device.instance =
            Device_Object_Instance_Number();
        notification.target_object.type = object_type;
        notification.target_object.instance = object_instance;
        notification.target_property.property_identifier =
            (BACNET_PROPERTY_ID)property_id;
        notification.target_property.property_array_index = BACNET_ARRAY_ALL;
        if (reporter->audit_log < BACNET_MAX_INSTANCE &&
            Audit_Log_Valid_Instance(reporter->audit_log)) {
            Audit_Log_Record_Notification_Insert(
                reporter->audit_log, &notification);
        }
        if (reporter->has_recipient &&
            bp_audit_resolve(&reporter->recipient, &dest)) {
            bp_audit_send(&dest, &notification);
        }
    }
}

void bp_audit_report_write(const BACNET_WRITE_PROPERTY_DATA *wp_data)
{
    if (!wp_data || bp_ar_count() == 0) {
        return;
    }
    bp_audit_report(
        AUDIT_OPERATION_WRITE, wp_data->object_type, wp_data->object_instance,
        wp_data->object_property);
}

void bp_audit_report_lifecycle(
    uint8_t operation, uint16_t object_type, uint32_t object_instance)
{
    if (bp_ar_count() == 0) {
        return;
    }
    bp_audit_report(
        operation, (BACNET_OBJECT_TYPE)object_type, object_instance,
        PROP_OBJECT_IDENTIFIER);
}

/* ---- AuditLogQuery (server) -------------------------------------------- */

void bp_on_audit_log_query(
    uint8_t *request,
    uint16_t len,
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_DATA *service_data)
{
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    uint8_t *buf = &Handler_Transmit_Buffer[0];
    BACNET_OBJECT_TYPE object_type = OBJECT_NONE;
    uint32_t object_instance = 0;
    BACNET_UNSIGNED_INTEGER start_at = 0;
    BACNET_UNSIGNED_INTEGER requested = 0;
    uint32_t count;
    uint32_t sent = 0;
    uint32_t index;
    int pdu_len;
    int offset = 0;
    int tag_len;
    bool more = false;

    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(&npdu_data, false, service_data->priority);
    pdu_len = npdu_encode_pdu(buf, src, &my_address, &npdu_data);
    if (service_data->segmented_message) {
        pdu_len += abort_encode_apdu(
            &buf[pdu_len], service_data->invoke_id,
            ABORT_REASON_SEGMENTATION_NOT_SUPPORTED, true);
        (void)datalink_send_pdu(src, &npdu_data, buf, pdu_len);
        return;
    }
    /* auditLog [0] BACnetObjectIdentifier */
    tag_len = bacnet_object_id_context_decode(
        &request[offset], len - offset, 0, &object_type, &object_instance);
    if (tag_len <= 0 || object_type != OBJECT_AUDIT_LOG ||
        !Audit_Log_Valid_Instance(object_instance)) {
        pdu_len += bacerror_encode_apdu(
            &buf[pdu_len], service_data->invoke_id,
            SERVICE_CONFIRMED_AUDIT_LOG_QUERY, ERROR_CLASS_OBJECT,
            ERROR_CODE_UNKNOWN_OBJECT);
        (void)datalink_send_pdu(src, &npdu_data, buf, pdu_len);
        return;
    }
    offset += tag_len;
    /* queryParameters [1] (ignored: this implementation returns all records) */
    if (bacnet_is_opening_tag_number(
            &request[offset], len - offset, 1, &tag_len)) {
        int depth = 1;
        offset += tag_len;
        while (depth > 0 && offset < len) {
            if (bacnet_is_opening_tag_number(
                    &request[offset], len - offset, 1, &tag_len)) {
                depth++;
                offset += tag_len;
            } else if (bacnet_is_closing_tag_number(
                           &request[offset], len - offset, 1, &tag_len)) {
                depth--;
                offset += tag_len;
            } else {
                offset++;
            }
        }
    }
    /* startAtSequenceNumber [2] Unsigned OPTIONAL */
    if (bacnet_is_context_tag_number(
            &request[offset], len - offset, 2, &tag_len, NULL)) {
        tag_len = bacnet_unsigned_context_decode(
            &request[offset], len - offset, 2, &start_at);
        if (tag_len > 0) {
            offset += tag_len;
        }
    }
    /* requestedCount [3] Unsigned OPTIONAL (0 or absent = all) */
    if (bacnet_is_context_tag_number(
            &request[offset], len - offset, 3, &tag_len, NULL)) {
        tag_len = bacnet_unsigned_context_decode(
            &request[offset], len - offset, 3, &requested);
        if (tag_len > 0) {
            offset += tag_len;
        }
    }
    count = Audit_Log_Record_Count(object_instance);
    buf[pdu_len++] = PDU_TYPE_COMPLEX_ACK;
    buf[pdu_len++] = service_data->invoke_id;
    buf[pdu_len++] = SERVICE_CONFIRMED_AUDIT_LOG_QUERY;
    /* auditLog [0] */
    pdu_len += encode_context_object_id(
        &buf[pdu_len], 0, OBJECT_AUDIT_LOG, object_instance);
    /* records [1] SEQUENCE OF BACnetAuditLogRecord */
    pdu_len += encode_opening_tag(&buf[pdu_len], 1);
    for (index = 0; index < count; index++) {
        BACNET_AUDIT_LOG_RECORD *record;
        int record_len;

        if (start_at > 0 && index + 1 < start_at) {
            continue;
        }
        if (requested > 0 && sent >= requested) {
            more = true;
            break;
        }
        record = Audit_Log_Record_Entry(object_instance, index);
        if (!record) {
            continue;
        }
        record_len = bacnet_audit_log_record_encode(NULL, record);
        if (pdu_len + record_len + 8 > (int)sizeof(Handler_Transmit_Buffer)) {
            more = true;
            break;
        }
        pdu_len += bacnet_audit_log_record_encode(&buf[pdu_len], record);
        sent++;
    }
    pdu_len += encode_closing_tag(&buf[pdu_len], 1);
    /* noMoreItems [2] BOOLEAN */
    pdu_len += encode_context_boolean(&buf[pdu_len], 2, !more);
    (void)datalink_send_pdu(src, &npdu_data, buf, pdu_len);
}
