/*
 * Server side of SubscribeCOVPropertyMultiple / COVNotificationMultiple
 * (ASHRAE 135 clauses 13.16, 13.17), which bacnet-stack does not implement.
 *
 * The engine keeps its own subscription table (independent of the single-COV
 * FSM's per-object latch): each subscribed property keeps a snapshot of its
 * last encoded value, taken with Device_Read_Property(). On the COV scan
 * tick every subscribed property is read again; the ones whose value changed
 * (a REAL present-value only past its COV increment) are grouped per object
 * into one COVNotificationMultiple and sent to the subscriber, confirmed or
 * unconfirmed as the subscription asked. Subscriptions expire with their
 * lifetime and a request without a lifetime (and without confirmed) cancels.
 */
#include <string.h>

#include "bacnet_plugin.h"
#include "bacnet/apdu.h"
#include "bacnet/bacaddr.h"
#include "bacnet/bacdcode.h"
#include "bacnet/bacerror.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/tsm/tsm.h"
#include "bacnet/datalink/datalink.h"
#include "bacnet/dcc.h"
#include "bacnet/npdu.h"
#include "bp_internal.h"

#ifndef BP_SCM_MAX_SUBSCRIPTIONS
#define BP_SCM_MAX_SUBSCRIPTIONS 32u
#endif
#ifndef BP_SCM_MAX_REFS
#define BP_SCM_MAX_REFS 16u
#endif
#define BP_SCM_VALUE_MAX 64u

typedef struct {
    uint16_t object_type;
    uint32_t object_instance;
    uint32_t property_id;
    uint32_t array_index; /* BACNET_ARRAY_ALL for the whole property */
    bool has_increment;
    float increment;
    bool valid; /* last holds a snapshot */
    uint8_t last_len;
    uint8_t last[BP_SCM_VALUE_MAX];
} bp_scm_ref_t;

typedef struct {
    bool active;
    BACNET_ADDRESS src;
    uint32_t process_id;
    bool confirmed;
    bool indefinite;
    uint32_t lifetime; /* seconds remaining, when !indefinite */
    uint32_t max_delay; /* seconds; 0 = only on change */
    uint32_t since_notify; /* seconds since the last notification */
    uint16_t ref_count;
    bp_scm_ref_t refs[BP_SCM_MAX_REFS];
} bp_scm_sub_t;

static bp_scm_sub_t bp_scm_subs[BP_SCM_MAX_SUBSCRIPTIONS];

/* ---- decoding ---------------------------------------------------------- */

/* A property reference of one object in the request. */
typedef struct {
    uint16_t object_type;
    uint32_t object_instance;
    uint32_t property_id;
    uint32_t array_index;
    bool has_increment;
    float increment;
} bp_scm_req_ref_t;

typedef struct {
    uint32_t process_id;
    bool has_confirmed;
    bool confirmed;
    bool has_lifetime;
    uint32_t lifetime;
    bool has_max_delay;
    uint32_t max_delay;
    uint16_t ref_count;
    bp_scm_req_ref_t refs[BP_SCM_MAX_REFS];
    /* the object and property of the first reference that overflowed or an
       error, for the SubscribeCOVPropertyMultiple-Error */
    bool overflow;
} bp_scm_request_t;

/* Decodes a SubscribeCOVPropertyMultiple request. Returns true on success. */
static bool bp_scm_decode(const uint8_t *apdu, uint16_t size, bp_scm_request_t *out)
{
    int len;
    int tag_len;
    uint32_t value = 0;
    BACNET_UNSIGNED_INTEGER unsigned_value = 0;
    int offset = 0;

    memset(out, 0, sizeof(*out));

    len = bacnet_unsigned_context_decode(
        &apdu[offset], size - offset, 0, &unsigned_value);
    if (len <= 0) {
        return false;
    }
    out->process_id = (uint32_t)unsigned_value;
    offset += len;

    if (bacnet_is_context_tag_number(
            &apdu[offset], size - offset, 1, &tag_len, &value)) {
        bool flag = false;
        len = bacnet_boolean_context_decode(&apdu[offset], size - offset, 1, &flag);
        if (len <= 0) {
            return false;
        }
        out->has_confirmed = true;
        out->confirmed = flag;
        offset += len;
    }
    if (bacnet_is_context_tag_number(
            &apdu[offset], size - offset, 2, &tag_len, &value)) {
        len = bacnet_unsigned_context_decode(
            &apdu[offset], size - offset, 2, &unsigned_value);
        if (len <= 0) {
            return false;
        }
        out->has_lifetime = true;
        out->lifetime = (uint32_t)unsigned_value;
        offset += len;
    }
    if (bacnet_is_context_tag_number(
            &apdu[offset], size - offset, 3, &tag_len, &value)) {
        len = bacnet_unsigned_context_decode(
            &apdu[offset], size - offset, 3, &unsigned_value);
        if (len <= 0) {
            return false;
        }
        out->has_max_delay = true;
        out->max_delay = (uint32_t)unsigned_value;
        offset += len;
    }
    if (!bacnet_is_opening_tag_number(&apdu[offset], size - offset, 4, &tag_len)) {
        return false;
    }
    offset += tag_len;
    while (!bacnet_is_closing_tag_number(
        &apdu[offset], size - offset, 4, &tag_len)) {
        BACNET_OBJECT_TYPE object_type = OBJECT_NONE;
        uint32_t instance = 0;

        len = bacnet_object_id_context_decode(
            &apdu[offset], size - offset, 0, &object_type, &instance);
        if (len <= 0) {
            return false;
        }
        offset += len;
        if (!bacnet_is_opening_tag_number(
                &apdu[offset], size - offset, 1, &tag_len)) {
            return false;
        }
        offset += tag_len;
        while (!bacnet_is_closing_tag_number(
            &apdu[offset], size - offset, 1, &tag_len)) {
            bp_scm_req_ref_t ref;

            memset(&ref, 0, sizeof(ref));
            ref.object_type = (uint16_t)object_type;
            ref.object_instance = instance;
            ref.array_index = BACNET_ARRAY_ALL;
            if (!bacnet_is_opening_tag_number(
                    &apdu[offset], size - offset, 0, &tag_len)) {
                return false;
            }
            offset += tag_len;
            len = bacnet_unsigned_context_decode(
                &apdu[offset], size - offset, 0, &unsigned_value);
            if (len <= 0) {
                return false;
            }
            ref.property_id = (uint32_t)unsigned_value;
            offset += len;
            if (bacnet_is_context_tag_number(
                    &apdu[offset], size - offset, 1, &tag_len, &value)) {
                len = bacnet_unsigned_context_decode(
                    &apdu[offset], size - offset, 1, &unsigned_value);
                if (len <= 0) {
                    return false;
                }
                ref.array_index = (uint32_t)unsigned_value;
                offset += len;
            }
            if (!bacnet_is_closing_tag_number(
                    &apdu[offset], size - offset, 0, &tag_len)) {
                return false;
            }
            offset += tag_len;
            if (bacnet_is_context_tag_number(
                    &apdu[offset], size - offset, 1, &tag_len, &value)) {
                float increment = 0.0f;
                len = bacnet_real_context_decode(
                    &apdu[offset], size - offset, 1, &increment);
                if (len <= 0) {
                    return false;
                }
                ref.has_increment = true;
                ref.increment = increment;
                offset += len;
            }
            if (bacnet_is_context_tag_number(
                    &apdu[offset], size - offset, 2, &tag_len, &value)) {
                bool timestamped = false;
                len = bacnet_boolean_context_decode(
                    &apdu[offset], size - offset, 2, &timestamped);
                if (len <= 0) {
                    return false;
                }
                offset += len;
            }
            if (out->ref_count < BP_SCM_MAX_REFS) {
                out->refs[out->ref_count++] = ref;
            } else {
                out->overflow = true;
            }
        }
        offset += tag_len; /* the closing [1] */
    }
    return true;
}

/* ---- snapshots and change detection ----------------------------------- */

/* Reads property [ref] into [value] (up to BP_SCM_VALUE_MAX). Returns the
   length, or a negative BACnet error class/code via *error_*. */
static int bp_scm_read(
    const bp_scm_req_ref_t *ref,
    uint8_t *value,
    BACNET_ERROR_CLASS *error_class,
    BACNET_ERROR_CODE *error_code)
{
    BACNET_READ_PROPERTY_DATA rpdata;
    int len;

    memset(&rpdata, 0, sizeof(rpdata));
    rpdata.object_type = (BACNET_OBJECT_TYPE)ref->object_type;
    rpdata.object_instance = ref->object_instance;
    rpdata.object_property = (BACNET_PROPERTY_ID)ref->property_id;
    rpdata.array_index = ref->array_index;
    rpdata.application_data = value;
    rpdata.application_data_len = BP_SCM_VALUE_MAX;
    rpdata.error_class = ERROR_CLASS_PROPERTY;
    rpdata.error_code = ERROR_CODE_UNKNOWN_PROPERTY;
    len = Device_Read_Property(&rpdata);
    if (len < 0) {
        *error_class = rpdata.error_class;
        *error_code = rpdata.error_code;
    }
    return len;
}

/* Reads [ref] again and reports whether its value changed since the snapshot;
   updates the snapshot. A REAL present-value changes only past its COV
   increment. */
static bool bp_scm_changed(bp_scm_ref_t *ref)
{
    uint8_t value[BP_SCM_VALUE_MAX];
    BACNET_READ_PROPERTY_DATA rpdata;
    int len;
    bool changed;

    memset(&rpdata, 0, sizeof(rpdata));
    rpdata.object_type = (BACNET_OBJECT_TYPE)ref->object_type;
    rpdata.object_instance = ref->object_instance;
    rpdata.object_property = (BACNET_PROPERTY_ID)ref->property_id;
    rpdata.array_index = ref->array_index;
    rpdata.application_data = value;
    rpdata.application_data_len = sizeof(value);
    len = Device_Read_Property(&rpdata);
    if (len < 0 || len > (int)sizeof(value)) {
        return false;
    }
    if (!ref->valid) {
        ref->valid = true;
        ref->last_len = (uint8_t)len;
        memcpy(ref->last, value, len);
        return false; /* first snapshot is the baseline */
    }
    changed = ref->last_len != len || memcmp(ref->last, value, len) != 0;
    if (changed && ref->has_increment &&
        ref->property_id == PROP_PRESENT_VALUE) {
        float current = 0.0f;
        float previous = 0.0f;
        if (bacnet_real_application_decode(value, len, &current) > 0 &&
            bacnet_real_application_decode(ref->last, ref->last_len, &previous) >
                0) {
            float delta = current > previous ? current - previous
                                             : previous - current;
            if (delta < ref->increment) {
                return false; /* within the increment: not reported */
            }
        }
    }
    if (changed) {
        ref->last_len = (uint8_t)len;
        memcpy(ref->last, value, len);
    }
    return changed;
}

/* ---- sending ----------------------------------------------------------- */

/* Sends one COVNotificationMultiple to [sub] reporting the refs whose
   [report] flag is set. */
static void bp_scm_notify(bp_scm_sub_t *sub, const bool *report)
{
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    uint8_t *buf = &Handler_Transmit_Buffer[0];
    int pdu_len;
    int apdu_len = 0;
    uint8_t invoke_id = 0;
    uint16_t i;

    if (!dcc_communication_enabled()) {
        return;
    }
    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(&npdu_data, sub->confirmed, MESSAGE_PRIORITY_NORMAL);
    pdu_len = npdu_encode_pdu(buf, &sub->src, &my_address, &npdu_data);
    if (sub->confirmed) {
        invoke_id = tsm_next_free_invokeID();
        if (!invoke_id) {
            return;
        }
        buf[pdu_len + apdu_len++] = PDU_TYPE_CONFIRMED_SERVICE_REQUEST;
        buf[pdu_len + apdu_len++] = 5; /* max APDU 1476, no segmentation */
        buf[pdu_len + apdu_len++] = invoke_id;
        buf[pdu_len + apdu_len++] =
            SERVICE_CONFIRMED_COV_NOTIFICATION_MULTIPLE;
    } else {
        buf[pdu_len + apdu_len++] = PDU_TYPE_UNCONFIRMED_SERVICE_REQUEST;
        buf[pdu_len + apdu_len++] =
            SERVICE_UNCONFIRMED_COV_NOTIFICATION_MULTIPLE;
    }
    {
        uint8_t *apdu = &buf[pdu_len];
        /* 0 = indefinite (ASHRAE 135: Time_Remaining 0 never expires) */
        uint32_t remaining = sub->indefinite ? 0 : sub->lifetime;
        apdu_len += encode_context_unsigned(&apdu[apdu_len], 0, sub->process_id);
        apdu_len += encode_context_object_id(
            &apdu[apdu_len], 1, OBJECT_DEVICE, Device_Object_Instance_Number());
        apdu_len += encode_context_unsigned(&apdu[apdu_len], 2, remaining);
        apdu_len += encode_opening_tag(&apdu[apdu_len], 4);
        for (i = 0; i < sub->ref_count;) {
            uint16_t j;
            /* group the reported refs that share this object */
            if (!report[i]) {
                i++;
                continue;
            }
            apdu_len += encode_context_object_id(
                &apdu[apdu_len], 0,
                (BACNET_OBJECT_TYPE)sub->refs[i].object_type,
                sub->refs[i].object_instance);
            apdu_len += encode_opening_tag(&apdu[apdu_len], 1);
            for (j = i; j < sub->ref_count; j++) {
                bp_scm_ref_t *ref = &sub->refs[j];
                if (!report[j] ||
                    ref->object_type != sub->refs[i].object_type ||
                    ref->object_instance != sub->refs[i].object_instance) {
                    continue;
                }
                apdu_len +=
                    encode_context_unsigned(&apdu[apdu_len], 0, ref->property_id);
                if (ref->array_index != BACNET_ARRAY_ALL) {
                    apdu_len += encode_context_unsigned(
                        &apdu[apdu_len], 1, ref->array_index);
                }
                apdu_len += encode_opening_tag(&apdu[apdu_len], 2);
                memcpy(&apdu[apdu_len], ref->last, ref->last_len);
                apdu_len += ref->last_len;
                apdu_len += encode_closing_tag(&apdu[apdu_len], 2);
            }
            apdu_len += encode_closing_tag(&apdu[apdu_len], 1);
            /* mark this object's refs as emitted so the outer loop skips them */
            for (j = i; j < sub->ref_count; j++) {
                if (sub->refs[j].object_type == sub->refs[i].object_type &&
                    sub->refs[j].object_instance ==
                        sub->refs[i].object_instance) {
                    ((bool *)report)[j] = false;
                }
            }
            i++;
        }
        apdu_len += encode_closing_tag(&apdu[apdu_len], 4);
    }
    pdu_len += apdu_len;
    if (pdu_len > (int)sizeof(Handler_Transmit_Buffer)) {
        return;
    }
    if (sub->confirmed) {
        tsm_set_confirmed_unsegmented_transaction(
            invoke_id, &sub->src, &npdu_data, buf, (uint16_t)pdu_len);
    }
    (void)datalink_send_pdu(&sub->src, &npdu_data, buf, pdu_len);
}

/* ---- subscription table ------------------------------------------------ */

static bp_scm_sub_t *bp_scm_find(const BACNET_ADDRESS *src, uint32_t process_id)
{
    uint16_t i;
    for (i = 0; i < BP_SCM_MAX_SUBSCRIPTIONS; i++) {
        if (bp_scm_subs[i].active &&
            bp_scm_subs[i].process_id == process_id &&
            bacnet_address_same(&bp_scm_subs[i].src, src)) {
            return &bp_scm_subs[i];
        }
    }
    return NULL;
}

static bp_scm_sub_t *bp_scm_free_slot(void)
{
    uint16_t i;
    for (i = 0; i < BP_SCM_MAX_SUBSCRIPTIONS; i++) {
        if (!bp_scm_subs[i].active) {
            return &bp_scm_subs[i];
        }
    }
    return NULL;
}

/* ---- response ---------------------------------------------------------- */

static void bp_scm_reply_ack(
    const BACNET_ADDRESS *src, const BACNET_CONFIRMED_SERVICE_DATA *service_data)
{
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    int len;

    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(&npdu_data, false, service_data->priority);
    len = npdu_encode_pdu(
        &Handler_Transmit_Buffer[0], (BACNET_ADDRESS *)src, &my_address,
        &npdu_data);
    len += encode_simple_ack(
        &Handler_Transmit_Buffer[len], service_data->invoke_id,
        SERVICE_CONFIRMED_SUBSCRIBE_COV_PROPERTY_MULTIPLE);
    (void)datalink_send_pdu(
        (BACNET_ADDRESS *)src, &npdu_data, &Handler_Transmit_Buffer[0], len);
}

/* Sends a SubscribeCOVPropertyMultiple-Error naming the first failed ref. */
static void bp_scm_reply_error(
    const BACNET_ADDRESS *src,
    const BACNET_CONFIRMED_SERVICE_DATA *service_data,
    const bp_scm_req_ref_t *ref,
    BACNET_ERROR_CLASS error_class,
    BACNET_ERROR_CODE error_code)
{
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    uint8_t *buf = &Handler_Transmit_Buffer[0];
    int pdu_len;
    int len;

    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(&npdu_data, false, service_data->priority);
    pdu_len = npdu_encode_pdu(buf, (BACNET_ADDRESS *)src, &my_address, &npdu_data);
    buf[pdu_len++] = PDU_TYPE_ERROR;
    buf[pdu_len++] = service_data->invoke_id;
    buf[pdu_len++] = SERVICE_CONFIRMED_SUBSCRIBE_COV_PROPERTY_MULTIPLE;
    /* [0] errorType */
    len = encode_opening_tag(&buf[pdu_len], 0);
    pdu_len += len;
    pdu_len += encode_application_enumerated(&buf[pdu_len], error_class);
    pdu_len += encode_application_enumerated(&buf[pdu_len], error_code);
    pdu_len += encode_closing_tag(&buf[pdu_len], 0);
    /* [1] firstFailedSubscription */
    pdu_len += encode_opening_tag(&buf[pdu_len], 1);
    pdu_len += encode_context_object_id(
        &buf[pdu_len], 0, (BACNET_OBJECT_TYPE)ref->object_type,
        ref->object_instance);
    pdu_len += encode_opening_tag(&buf[pdu_len], 1);
    pdu_len += encode_context_unsigned(&buf[pdu_len], 0, ref->property_id);
    if (ref->array_index != BACNET_ARRAY_ALL) {
        pdu_len += encode_context_unsigned(&buf[pdu_len], 1, ref->array_index);
    }
    pdu_len += encode_closing_tag(&buf[pdu_len], 1);
    pdu_len += encode_opening_tag(&buf[pdu_len], 2);
    pdu_len += encode_application_enumerated(&buf[pdu_len], error_class);
    pdu_len += encode_application_enumerated(&buf[pdu_len], error_code);
    pdu_len += encode_closing_tag(&buf[pdu_len], 2);
    pdu_len += encode_closing_tag(&buf[pdu_len], 1);
    (void)datalink_send_pdu(
        (BACNET_ADDRESS *)src, &npdu_data, buf, pdu_len);
}

/* ---- handler ----------------------------------------------------------- */

void bp_scm_handler(
    uint8_t *request,
    uint16_t len,
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_DATA *service_data)
{
    bp_scm_request_t req;
    bp_scm_sub_t *sub;
    uint16_t i;
    BACNET_ERROR_CLASS error_class = ERROR_CLASS_OBJECT;
    BACNET_ERROR_CODE error_code = ERROR_CODE_UNKNOWN_OBJECT;

    if (service_data->segmented_message) {
        return; /* the apdu layer answers segmented requests with an abort */
    }
    if (!bp_scm_decode(request, len, &req) || req.ref_count == 0) {
        bp_scm_req_ref_t none = { 0 };
        bp_scm_reply_error(
            src, service_data, &none, ERROR_CLASS_SERVICES,
            ERROR_CODE_INCONSISTENT_PARAMETERS);
        return;
    }
    /* a request without confirmed and without lifetime cancels */
    if (!req.has_confirmed && !req.has_lifetime) {
        sub = bp_scm_find(src, req.process_id);
        if (sub) {
            sub->active = false;
        }
        bp_scm_reply_ack(src, service_data);
        return;
    }
    /* validate every reference before subscribing (atomic) */
    for (i = 0; i < req.ref_count; i++) {
        uint8_t value[BP_SCM_VALUE_MAX];
        if (bp_scm_read(&req.refs[i], value, &error_class, &error_code) < 0) {
            bp_scm_reply_error(
                src, service_data, &req.refs[i], error_class, error_code);
            return;
        }
    }
    sub = bp_scm_find(src, req.process_id);
    if (!sub) {
        sub = bp_scm_free_slot();
    }
    if (!sub) {
        bp_scm_reply_error(
            src, service_data, &req.refs[0], ERROR_CLASS_RESOURCES,
            ERROR_CODE_NO_SPACE_TO_ADD_LIST_ELEMENT);
        return;
    }
    memset(sub, 0, sizeof(*sub));
    sub->active = true;
    sub->src = *src;
    sub->process_id = req.process_id;
    sub->confirmed = req.has_confirmed && req.confirmed;
    sub->indefinite = !req.has_lifetime || req.lifetime == 0;
    sub->lifetime = req.has_lifetime ? req.lifetime : 0;
    sub->max_delay = req.has_max_delay ? req.max_delay : 0;
    sub->ref_count = req.ref_count;
    for (i = 0; i < req.ref_count; i++) {
        sub->refs[i].object_type = req.refs[i].object_type;
        sub->refs[i].object_instance = req.refs[i].object_instance;
        sub->refs[i].property_id = req.refs[i].property_id;
        sub->refs[i].array_index = req.refs[i].array_index;
        sub->refs[i].has_increment = req.refs[i].has_increment;
        sub->refs[i].increment = req.refs[i].increment;
    }
    bp_scm_reply_ack(src, service_data);
    /* take the baseline snapshots and send the initial notification */
    {
        bool report[BP_SCM_MAX_REFS];
        bool any = false;
        for (i = 0; i < sub->ref_count; i++) {
            (void)bp_scm_changed(&sub->refs[i]); /* baseline */
            report[i] = true;
            any = true;
        }
        if (any) {
            sub->since_notify = 0;
            bp_scm_notify(sub, report);
        }
    }
}

/* ---- periodic task ----------------------------------------------------- */

void bp_scm_task(uint32_t seconds)
{
    uint16_t s;

    if (!bp_state.server_enabled) {
        return;
    }
    for (s = 0; s < BP_SCM_MAX_SUBSCRIPTIONS; s++) {
        bp_scm_sub_t *sub = &bp_scm_subs[s];
        bool report[BP_SCM_MAX_REFS];
        bool any_change = false;
        bool force;
        uint16_t i;

        if (!sub->active) {
            continue;
        }
        if (!sub->indefinite) {
            if (sub->lifetime <= seconds) {
                sub->active = false;
                continue;
            }
            sub->lifetime -= seconds;
        }
        if (sub->max_delay) {
            sub->since_notify += seconds;
        }
        force = sub->max_delay && sub->since_notify >= sub->max_delay;
        for (i = 0; i < sub->ref_count; i++) {
            report[i] = bp_scm_changed(&sub->refs[i]);
            if (report[i]) {
                any_change = true;
            }
        }
        if (force && !any_change) {
            for (i = 0; i < sub->ref_count; i++) {
                report[i] = true;
            }
            any_change = true;
        }
        if (any_change) {
            sub->since_notify = 0;
            bp_scm_notify(sub, report);
        }
    }
}

void bp_scm_reset(void)
{
    memset(bp_scm_subs, 0, sizeof(bp_scm_subs));
}
