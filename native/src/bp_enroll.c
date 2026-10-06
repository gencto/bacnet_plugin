/*
 * Server side of GetEnrollmentSummary (ASHRAE 135 clause 13.12), which
 * bacnet-stack does not implement. It enumerates the device's event-initiating
 * objects (those with an Event_State property: intrinsic-reporting objects and
 * Event Enrollment objects), applies the request's filters, and returns a
 * summary of each: object identifier, event type, event state, notification
 * priority and notification class.
 */
#include <string.h>

#include "bacnet_plugin.h"
#include "bacnet/abort.h"
#include "bacnet/apdu.h"
#include "bacnet/bacdcode.h"
#include "bacnet/bacerror.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/tsm/tsm.h"
#include "bacnet/datalink/datalink.h"
#include "bacnet/npdu.h"
#include "bp_internal.h"

typedef struct {
    uint32_t ack_filter; /* 0 all, 1 acked, 2 not-acked */
    bool has_state;
    uint32_t state_filter; /* BACNET_EVENT_STATE_FILTER */
    bool has_type;
    uint32_t event_type;
    bool has_priority;
    uint32_t priority_min;
    uint32_t priority_max;
    bool has_class;
    uint32_t notification_class;
} bp_enroll_filter_t;

/* Reads [property] of an object as an application enumerated/unsigned value.
   Returns true and sets *value, or false when the object lacks it. */
static bool bp_enroll_read_uint(
    BACNET_OBJECT_TYPE type,
    uint32_t instance,
    BACNET_PROPERTY_ID property,
    bool enumerated,
    uint32_t *value)
{
    uint8_t buffer[16];
    BACNET_READ_PROPERTY_DATA rpdata;
    int len;

    memset(&rpdata, 0, sizeof(rpdata));
    rpdata.object_type = type;
    rpdata.object_instance = instance;
    rpdata.object_property = property;
    rpdata.array_index = BACNET_ARRAY_ALL;
    rpdata.application_data = buffer;
    rpdata.application_data_len = sizeof(buffer);
    len = Device_Read_Property(&rpdata);
    if (len <= 0) {
        return false;
    }
    if (enumerated) {
        uint32_t result = 0;
        if (bacnet_enumerated_application_decode(buffer, len, &result) <= 0) {
            return false;
        }
        *value = result;
    } else {
        BACNET_UNSIGNED_INTEGER result = 0;
        if (bacnet_unsigned_application_decode(buffer, len, &result) <= 0) {
            return false;
        }
        *value = (uint32_t)result;
    }
    return true;
}

/* Reads Acked_Transitions; true when all three transitions are acknowledged. */
static bool bp_enroll_all_acked(BACNET_OBJECT_TYPE type, uint32_t instance)
{
    uint8_t buffer[16];
    BACNET_READ_PROPERTY_DATA rpdata;
    BACNET_BIT_STRING bits;
    int len;
    unsigned i;

    memset(&rpdata, 0, sizeof(rpdata));
    rpdata.object_type = type;
    rpdata.object_instance = instance;
    rpdata.object_property = PROP_ACKED_TRANSITIONS;
    rpdata.array_index = BACNET_ARRAY_ALL;
    rpdata.application_data = buffer;
    rpdata.application_data_len = sizeof(buffer);
    len = Device_Read_Property(&rpdata);
    if (len <= 0 || bacnet_bitstring_application_decode(buffer, len, &bits) <= 0) {
        return true; /* no Acked_Transitions: treat as acknowledged */
    }
    for (i = 0; i < bitstring_bits_used(&bits); i++) {
        if (!bitstring_bit(&bits, (uint8_t)i)) {
            return false;
        }
    }
    return true;
}

/* An event type for an object that has no Event_Type property, inferred from
   its object type (analog ranges vs. discrete states). */
static uint32_t bp_enroll_default_type(BACNET_OBJECT_TYPE type)
{
    switch (type) {
        case OBJECT_ANALOG_INPUT:
        case OBJECT_ANALOG_OUTPUT:
        case OBJECT_ANALOG_VALUE:
        case OBJECT_INTEGER_VALUE:
        case OBJECT_POSITIVE_INTEGER_VALUE:
        case OBJECT_LARGE_ANALOG_VALUE:
            return EVENT_OUT_OF_RANGE;
        default:
            return EVENT_CHANGE_OF_STATE;
    }
}

static bool bp_enroll_state_matches(uint32_t filter, uint32_t state)
{
    switch (filter) {
        case EVENT_STATE_FILTER_OFFNORMAL:
            return state == EVENT_STATE_HIGH_LIMIT ||
                state == EVENT_STATE_LOW_LIMIT ||
                state == EVENT_STATE_OFFNORMAL;
        case EVENT_STATE_FILTER_FAULT:
            return state == EVENT_STATE_FAULT;
        case EVENT_STATE_FILTER_NORMAL:
            return state == EVENT_STATE_NORMAL;
        case EVENT_STATE_FILTER_ACTIVE:
            return state != EVENT_STATE_NORMAL;
        case EVENT_STATE_FILTER_ALL:
        default:
            return true;
    }
}

/* Decodes the request filters. Returns true on success. */
static bool bp_enroll_decode(
    const uint8_t *apdu, uint16_t size, bp_enroll_filter_t *out)
{
    int len;
    int tag_len;
    uint32_t value = 0;
    BACNET_UNSIGNED_INTEGER unsigned_value = 0;
    int offset = 0;

    memset(out, 0, sizeof(*out));
    out->ack_filter = 0;
    out->priority_min = 0;
    out->priority_max = 255;

    len = bacnet_enumerated_context_decode(&apdu[offset], size - offset, 0, &value);
    if (len <= 0) {
        return false;
    }
    out->ack_filter = value;
    offset += len;
    /* [1] enrollmentFilter (BACnetRecipientProcess) is skipped if present */
    if (bacnet_is_opening_tag_number(&apdu[offset], size - offset, 1, &tag_len)) {
        int depth = 1;
        offset += tag_len;
        while (depth > 0 && offset < size) {
            if (bacnet_is_opening_tag_number(
                    &apdu[offset], size - offset, 1, &tag_len)) {
                depth++;
                offset += tag_len;
            } else if (bacnet_is_closing_tag_number(
                           &apdu[offset], size - offset, 1, &tag_len)) {
                depth--;
                offset += tag_len;
            } else {
                offset++;
            }
        }
    }
    if (bacnet_is_context_tag_number(
            &apdu[offset], size - offset, 2, &tag_len, &value)) {
        len = bacnet_enumerated_context_decode(
            &apdu[offset], size - offset, 2, &value);
        if (len <= 0) {
            return false;
        }
        out->has_state = true;
        out->state_filter = value;
        offset += len;
    }
    if (bacnet_is_context_tag_number(
            &apdu[offset], size - offset, 3, &tag_len, &value)) {
        len = bacnet_enumerated_context_decode(
            &apdu[offset], size - offset, 3, &value);
        if (len <= 0) {
            return false;
        }
        out->has_type = true;
        out->event_type = value;
        offset += len;
    }
    if (bacnet_is_opening_tag_number(&apdu[offset], size - offset, 4, &tag_len)) {
        offset += tag_len;
        len = bacnet_unsigned_context_decode(
            &apdu[offset], size - offset, 0, &unsigned_value);
        if (len <= 0) {
            return false;
        }
        out->priority_min = (uint32_t)unsigned_value;
        offset += len;
        len = bacnet_unsigned_context_decode(
            &apdu[offset], size - offset, 1, &unsigned_value);
        if (len <= 0) {
            return false;
        }
        out->priority_max = (uint32_t)unsigned_value;
        offset += len;
        if (!bacnet_is_closing_tag_number(
                &apdu[offset], size - offset, 4, &tag_len)) {
            return false;
        }
        out->has_priority = true;
        offset += tag_len;
    }
    if (bacnet_is_context_tag_number(
            &apdu[offset], size - offset, 5, &tag_len, &value)) {
        len = bacnet_unsigned_context_decode(
            &apdu[offset], size - offset, 5, &unsigned_value);
        if (len <= 0) {
            return false;
        }
        out->has_class = true;
        out->notification_class = (uint32_t)unsigned_value;
    }
    return true;
}

void bp_on_get_enrollment_summary(
    uint8_t *request,
    uint16_t len,
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_DATA *service_data)
{
    bp_enroll_filter_t filter;
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    uint8_t *buf = &Handler_Transmit_Buffer[0];
    int pdu_len;
    unsigned count;
    unsigned i;

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
    if (!bp_enroll_decode(request, len, &filter)) {
        pdu_len += bacerror_encode_apdu(
            &buf[pdu_len], service_data->invoke_id,
            SERVICE_CONFIRMED_GET_ENROLLMENT_SUMMARY, ERROR_CLASS_SERVICES,
            ERROR_CODE_INCONSISTENT_PARAMETERS);
        (void)datalink_send_pdu(src, &npdu_data, buf, pdu_len);
        return;
    }
    buf[pdu_len++] = PDU_TYPE_COMPLEX_ACK;
    buf[pdu_len++] = service_data->invoke_id;
    buf[pdu_len++] = SERVICE_CONFIRMED_GET_ENROLLMENT_SUMMARY;
    count = Device_Object_List_Count();
    for (i = 1; i <= count; i++) {
        BACNET_OBJECT_TYPE type = OBJECT_NONE;
        uint32_t instance = 0;
        uint32_t state = 0;
        uint32_t event_type = 0;
        uint32_t notification_class = 0;
        bool has_class;

        if (!Device_Object_List_Identifier(i, &type, &instance)) {
            continue;
        }
        if (!bp_enroll_read_uint(
                type, instance, PROP_EVENT_STATE, true, &state)) {
            continue; /* no Event_State: not an event-initiating object */
        }
        /* an object is event-initiating once it has a real Notification_Class;
           unconfigured objects keep BACNET_MAX_INSTANCE */
        has_class = bp_enroll_read_uint(
            type, instance, PROP_NOTIFICATION_CLASS, false,
            &notification_class);
        if (!has_class || notification_class >= BACNET_MAX_INSTANCE) {
            continue;
        }
        if (!bp_enroll_read_uint(
                type, instance, PROP_EVENT_TYPE, true, &event_type)) {
            event_type = bp_enroll_default_type(type);
        }
        /* filters */
        if (filter.ack_filter == 1 && !bp_enroll_all_acked(type, instance)) {
            continue;
        }
        if (filter.ack_filter == 2 && bp_enroll_all_acked(type, instance)) {
            continue;
        }
        if (filter.has_state &&
            !bp_enroll_state_matches(filter.state_filter, state)) {
            continue;
        }
        if (filter.has_type && filter.event_type != event_type) {
            continue;
        }
        if (filter.has_class &&
            (!has_class || filter.notification_class != notification_class)) {
            continue;
        }
        /* priority is reported as 0, so a minimum above 0 excludes everything */
        if (filter.has_priority && filter.priority_min > 0) {
            continue;
        }
        if (pdu_len + 24 > (int)sizeof(Handler_Transmit_Buffer)) {
            break;
        }
        pdu_len += encode_application_object_id(&buf[pdu_len], type, instance);
        pdu_len += encode_application_enumerated(&buf[pdu_len], event_type);
        pdu_len += encode_application_enumerated(&buf[pdu_len], state);
        pdu_len += encode_application_unsigned(&buf[pdu_len], 0); /* priority */
        if (has_class) {
            pdu_len +=
                encode_application_unsigned(&buf[pdu_len], notification_class);
        }
    }
    (void)datalink_send_pdu(src, &npdu_data, buf, pdu_len);
}
