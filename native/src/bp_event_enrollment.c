/*
 * Event Enrollment object (ASHRAE 135 clause 12.12), which bacnet-stack does
 * not implement. An Event Enrollment monitors a referenced property with an
 * event algorithm and reports transitions to a Notification Class. This
 * implementation supports the OUT_OF_RANGE algorithm (the common case): it
 * watches a REAL property against high/low limits with a deadband and a time
 * delay, and emits event notifications through the same path the intrinsic
 * objects use (Notification_Class_common_reporting_function).
 */
#include <string.h>

#include "bacnet_plugin.h"
#include "bacnet/bacdcode.h"
#include "bacnet/bacdevobjpropref.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/object/nc.h"
#include "bacnet/datetime.h"
#include "bacnet/proplist.h"
#include "bp_internal.h"

#if defined(INTRINSIC_REPORTING)

#ifndef BP_EE_MAX
#define BP_EE_MAX 16u
#endif

typedef struct {
    bool used;
    const char *name;
    const char *description;
    /* monitored property */
    uint16_t monitored_type;
    uint32_t monitored_instance;
    uint32_t monitored_property;
    uint32_t monitored_index;
    /* OUT_OF_RANGE parameters */
    float high_limit;
    float low_limit;
    float deadband;
    uint32_t time_delay; /* seconds */
    uint32_t notification_class;
    uint8_t event_enable; /* bit0 to-offnormal, bit1 to-fault, bit2 to-normal */
    uint8_t notify_type;
    /* state */
    uint8_t event_state;
    bool acked[MAX_BACNET_EVENT_TRANSITION];
    BACNET_DATE_TIME stamps[MAX_BACNET_EVENT_TRANSITION];
    uint8_t pending_to; /* the state the delay is counting toward */
    uint32_t pending_elapsed;
} bp_ee_t;

static bp_ee_t bp_ee[BP_EE_MAX];

static const int32_t bp_ee_required[] = { PROP_OBJECT_IDENTIFIER,
                                          PROP_OBJECT_NAME,
                                          PROP_OBJECT_TYPE,
                                          PROP_EVENT_TYPE,
                                          PROP_NOTIFY_TYPE,
                                          PROP_EVENT_PARAMETERS,
                                          PROP_OBJECT_PROPERTY_REFERENCE,
                                          PROP_EVENT_STATE,
                                          PROP_EVENT_ENABLE,
                                          PROP_ACKED_TRANSITIONS,
                                          PROP_NOTIFICATION_CLASS,
                                          PROP_EVENT_TIME_STAMPS,
                                          PROP_EVENT_DETECTION_ENABLE,
                                          PROP_STATUS_FLAGS,
                                          PROP_RELIABILITY,
                                          -1 };
static const int32_t bp_ee_optional[] = { PROP_DESCRIPTION, -1 };
static const int32_t bp_ee_proprietary[] = { -1 };

void bp_ee_init(void)
{
    memset(bp_ee, 0, sizeof(bp_ee));
}

bool bp_ee_valid_instance(uint32_t instance)
{
    return instance < BP_EE_MAX && bp_ee[instance].used;
}

unsigned bp_ee_count(void)
{
    unsigned count = 0;
    unsigned i;

    for (i = 0; i < BP_EE_MAX; i++) {
        if (bp_ee[i].used) {
            count++;
        }
    }
    return count;
}

uint32_t bp_ee_index_to_instance(unsigned index)
{
    unsigned i;

    for (i = 0; i < BP_EE_MAX; i++) {
        if (bp_ee[i].used) {
            if (index == 0) {
                return i;
            }
            index--;
        }
    }
    return BP_EE_MAX;
}

bool bp_ee_object_name(uint32_t instance, BACNET_CHARACTER_STRING *name)
{
    char buffer[32];

    if (!bp_ee_valid_instance(instance)) {
        return false;
    }
    if (bp_ee[instance].name) {
        return characterstring_init_ansi(name, bp_ee[instance].name);
    }
    snprintf(buffer, sizeof(buffer), "EE-%lu", (unsigned long)instance);
    return characterstring_init_ansi(name, buffer);
}

bool bp_ee_name_set(uint32_t instance, const char *name)
{
    if (!bp_ee_valid_instance(instance)) {
        return false;
    }
    bp_ee[instance].name = name;
    return true;
}

bool bp_ee_description_set(uint32_t instance, const char *description)
{
    if (!bp_ee_valid_instance(instance)) {
        return false;
    }
    bp_ee[instance].description = description;
    return true;
}

void bp_ee_property_lists(
    const int32_t **required,
    const int32_t **optional,
    const int32_t **proprietary)
{
    if (required) {
        *required = bp_ee_required;
    }
    if (optional) {
        *optional = bp_ee_optional;
    }
    if (proprietary) {
        *proprietary = bp_ee_proprietary;
    }
}

/* Encodes the OUT_OF_RANGE Event_Parameters: [5] { [0] time-delay,
   [1] low-limit, [2] high-limit, [3] deadband }. */
static int bp_ee_encode_parameters(uint8_t *apdu, const bp_ee_t *object)
{
    int len = 0;

    len += encode_opening_tag(&apdu[len], 5);
    len += encode_context_unsigned(&apdu[len], 0, object->time_delay);
    len += encode_context_real(&apdu[len], 1, object->low_limit);
    len += encode_context_real(&apdu[len], 2, object->high_limit);
    len += encode_context_real(&apdu[len], 3, object->deadband);
    len += encode_closing_tag(&apdu[len], 5);
    return len;
}

int bp_ee_read_property(BACNET_READ_PROPERTY_DATA *rpdata)
{
    bp_ee_t *object;
    uint8_t *apdu;
    int len = 0;
    BACNET_CHARACTER_STRING text;
    BACNET_BIT_STRING bits;
    unsigned i;

    if (!rpdata || !rpdata->application_data ||
        rpdata->application_data_len <= 0) {
        return 0;
    }
    if (!bp_ee_valid_instance(rpdata->object_instance)) {
        rpdata->error_class = ERROR_CLASS_OBJECT;
        rpdata->error_code = ERROR_CODE_UNKNOWN_OBJECT;
        return BACNET_STATUS_ERROR;
    }
    object = &bp_ee[rpdata->object_instance];
    apdu = rpdata->application_data;
    switch (rpdata->object_property) {
        case PROP_OBJECT_IDENTIFIER:
            len = encode_application_object_id(
                apdu, OBJECT_EVENT_ENROLLMENT, rpdata->object_instance);
            break;
        case PROP_OBJECT_NAME:
            bp_ee_object_name(rpdata->object_instance, &text);
            len = encode_application_character_string(apdu, &text);
            break;
        case PROP_DESCRIPTION:
            characterstring_init_ansi(
                &text, object->description ? object->description : "");
            len = encode_application_character_string(apdu, &text);
            break;
        case PROP_OBJECT_TYPE:
            len = encode_application_enumerated(apdu, OBJECT_EVENT_ENROLLMENT);
            break;
        case PROP_EVENT_TYPE:
            len = encode_application_enumerated(apdu, EVENT_OUT_OF_RANGE);
            break;
        case PROP_NOTIFY_TYPE:
            len = encode_application_enumerated(apdu, object->notify_type);
            break;
        case PROP_EVENT_PARAMETERS:
            len = bp_ee_encode_parameters(apdu, object);
            break;
        case PROP_OBJECT_PROPERTY_REFERENCE: {
            BACNET_DEVICE_OBJECT_PROPERTY_REFERENCE reference;
            memset(&reference, 0, sizeof(reference));
            reference.objectIdentifier.type =
                (BACNET_OBJECT_TYPE)object->monitored_type;
            reference.objectIdentifier.instance = object->monitored_instance;
            reference.propertyIdentifier =
                (BACNET_PROPERTY_ID)object->monitored_property;
            reference.arrayIndex = object->monitored_index;
            reference.deviceIdentifier.type = OBJECT_DEVICE;
            reference.deviceIdentifier.instance = BACNET_MAX_INSTANCE;
            len = bacapp_encode_device_obj_property_ref(apdu, &reference);
            break;
        }
        case PROP_EVENT_STATE:
            len = encode_application_enumerated(apdu, object->event_state);
            break;
        case PROP_EVENT_DETECTION_ENABLE:
            len = encode_application_boolean(apdu, true);
            break;
        case PROP_EVENT_ENABLE:
            bitstring_init(&bits);
            bitstring_set_bit(
                &bits, TRANSITION_TO_OFFNORMAL,
                (object->event_enable & 1) != 0);
            bitstring_set_bit(
                &bits, TRANSITION_TO_FAULT, (object->event_enable & 2) != 0);
            bitstring_set_bit(
                &bits, TRANSITION_TO_NORMAL, (object->event_enable & 4) != 0);
            len = encode_application_bitstring(apdu, &bits);
            break;
        case PROP_ACKED_TRANSITIONS:
            bitstring_init(&bits);
            bitstring_set_bit(
                &bits, TRANSITION_TO_OFFNORMAL,
                object->acked[TRANSITION_TO_OFFNORMAL]);
            bitstring_set_bit(
                &bits, TRANSITION_TO_FAULT, object->acked[TRANSITION_TO_FAULT]);
            bitstring_set_bit(
                &bits, TRANSITION_TO_NORMAL,
                object->acked[TRANSITION_TO_NORMAL]);
            len = encode_application_bitstring(apdu, &bits);
            break;
        case PROP_NOTIFICATION_CLASS:
            len = encode_application_unsigned(apdu, object->notification_class);
            break;
        case PROP_STATUS_FLAGS:
            bitstring_init(&bits);
            bitstring_set_bit(
                &bits, STATUS_FLAG_IN_ALARM,
                object->event_state != EVENT_STATE_NORMAL);
            bitstring_set_bit(&bits, STATUS_FLAG_FAULT, false);
            bitstring_set_bit(&bits, STATUS_FLAG_OVERRIDDEN, false);
            bitstring_set_bit(&bits, STATUS_FLAG_OUT_OF_SERVICE, false);
            len = encode_application_bitstring(apdu, &bits);
            break;
        case PROP_RELIABILITY:
            len = encode_application_enumerated(
                apdu, RELIABILITY_NO_FAULT_DETECTED);
            break;
        case PROP_EVENT_TIME_STAMPS:
            if (rpdata->array_index == 0) {
                len = encode_application_unsigned(
                    apdu, MAX_BACNET_EVENT_TRANSITION);
            } else {
                int item;
                for (i = 0; i < MAX_BACNET_EVENT_TRANSITION; i++) {
                    if (rpdata->array_index != BACNET_ARRAY_ALL &&
                        rpdata->array_index != i + 1) {
                        continue;
                    }
                    item = encode_opening_tag(&apdu[len], 2);
                    item += encode_application_date(
                        &apdu[len + item], &object->stamps[i].date);
                    item += encode_application_time(
                        &apdu[len + item], &object->stamps[i].time);
                    item += encode_closing_tag(&apdu[len + item], 2);
                    len += item;
                }
            }
            break;
        default:
            rpdata->error_class = ERROR_CLASS_PROPERTY;
            rpdata->error_code = ERROR_CODE_UNKNOWN_PROPERTY;
            return BACNET_STATUS_ERROR;
    }
    return len;
}

bool bp_ee_write_property(BACNET_WRITE_PROPERTY_DATA *wp_data)
{
    if (wp_data) {
        wp_data->error_class = ERROR_CLASS_PROPERTY;
        wp_data->error_code = ERROR_CODE_WRITE_ACCESS_DENIED;
    }
    return false;
}

uint32_t bp_ee_create(uint32_t instance)
{
    unsigned i;

    if (instance == BACNET_MAX_INSTANCE) {
        for (i = 0; i < BP_EE_MAX; i++) {
            if (!bp_ee[i].used) {
                instance = i;
                break;
            }
        }
    }
    if (instance >= BP_EE_MAX) {
        return BACNET_MAX_INSTANCE;
    }
    if (!bp_ee[instance].used) {
        memset(&bp_ee[instance], 0, sizeof(bp_ee[instance]));
        bp_ee[instance].used = true;
        bp_ee[instance].event_state = EVENT_STATE_NORMAL;
        bp_ee[instance].pending_to = EVENT_STATE_NORMAL;
        bp_ee[instance].notify_type = NOTIFY_ALARM;
        bp_ee[instance].acked[0] = true;
        bp_ee[instance].acked[1] = true;
        bp_ee[instance].acked[2] = true;
        bp_ee[instance].monitored_index = BACNET_ARRAY_ALL;
        bp_ee[instance].notification_class = BACNET_MAX_INSTANCE;
    }
    return instance;
}

bool bp_ee_delete(uint32_t instance)
{
    if (!bp_ee_valid_instance(instance)) {
        return false;
    }
    bp_ee[instance].used = false;
    return true;
}

BP_API int32_t bacnet_plugin_event_enrollment_configure(
    uint32_t instance,
    uint16_t monitored_type,
    uint32_t monitored_instance,
    uint32_t monitored_property,
    uint32_t monitored_index,
    float low_limit,
    float high_limit,
    float deadband,
    uint32_t time_delay,
    uint32_t notification_class,
    uint8_t event_enable,
    uint8_t notify_type)
{
    bp_ee_t *object;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!bp_ee_valid_instance(instance)) {
        return BP_ERR_OBJECT;
    }
    object = &bp_ee[instance];
    object->monitored_type = monitored_type;
    object->monitored_instance = monitored_instance;
    object->monitored_property = monitored_property;
    object->monitored_index = monitored_index;
    object->low_limit = low_limit;
    object->high_limit = high_limit;
    object->deadband = deadband;
    object->time_delay = time_delay;
    object->notification_class = notification_class;
    object->event_enable = event_enable;
    object->notify_type = notify_type;
    return BP_OK;
}

/* Reads the monitored property as a REAL; returns false when unavailable. */
static bool bp_ee_monitored_value(const bp_ee_t *object, float *value)
{
    uint8_t buffer[16];
    BACNET_READ_PROPERTY_DATA rpdata;
    int len;

    memset(&rpdata, 0, sizeof(rpdata));
    rpdata.object_type = (BACNET_OBJECT_TYPE)object->monitored_type;
    rpdata.object_instance = object->monitored_instance;
    rpdata.object_property = (BACNET_PROPERTY_ID)object->monitored_property;
    rpdata.array_index = object->monitored_index;
    rpdata.application_data = buffer;
    rpdata.application_data_len = sizeof(buffer);
    len = Device_Read_Property(&rpdata);
    if (len <= 0) {
        return false;
    }
    return bacnet_real_application_decode(buffer, len, value) > 0;
}

/* Sends an OUT_OF_RANGE event notification for a transition. */
static void bp_ee_notify(
    bp_ee_t *object,
    uint32_t instance,
    uint8_t from_state,
    uint8_t to_state,
    float value,
    float exceeded_limit)
{
    BACNET_EVENT_NOTIFICATION_DATA data;
    uint32_t priorities[MAX_BACNET_EVENT_TRANSITION] = { 255, 255, 255 };
    uint8_t ack_required = 0;
    unsigned transition;

    memset(&data, 0, sizeof(data));
    Notification_Class_Get_Priorities(object->notification_class, priorities);
    Notification_Class_Get_Ack_Required(
        object->notification_class, &ack_required);
    transition = to_state == EVENT_STATE_NORMAL ? TRANSITION_TO_NORMAL
                                                : TRANSITION_TO_OFFNORMAL;
    data.processIdentifier = 0;
    data.initiatingObjectIdentifier.type = OBJECT_DEVICE;
    data.initiatingObjectIdentifier.instance = Device_Object_Instance_Number();
    data.eventObjectIdentifier.type = OBJECT_EVENT_ENROLLMENT;
    data.eventObjectIdentifier.instance = instance;
    data.timeStamp.tag = TIME_STAMP_DATETIME;
    Device_getCurrentDateTime(&data.timeStamp.value.dateTime);
    object->stamps[transition] = data.timeStamp.value.dateTime;
    data.notificationClass = object->notification_class;
    data.priority = priorities[transition];
    data.eventType = EVENT_OUT_OF_RANGE;
    data.notifyType = (BACNET_NOTIFY_TYPE)object->notify_type;
    data.ackRequired = (ack_required & (1u << transition)) != 0 &&
        object->notify_type == NOTIFY_ALARM;
    data.fromState = (BACNET_EVENT_STATE)from_state;
    data.toState = (BACNET_EVENT_STATE)to_state;
    data.notificationParams.outOfRange.exceedingValue = value;
    data.notificationParams.outOfRange.deadband = object->deadband;
    data.notificationParams.outOfRange.exceededLimit = exceeded_limit;
    bitstring_init(&data.notificationParams.outOfRange.statusFlags);
    bitstring_set_bit(
        &data.notificationParams.outOfRange.statusFlags, STATUS_FLAG_IN_ALARM,
        to_state != EVENT_STATE_NORMAL);
    bitstring_set_bit(
        &data.notificationParams.outOfRange.statusFlags, STATUS_FLAG_FAULT,
        false);
    bitstring_set_bit(
        &data.notificationParams.outOfRange.statusFlags, STATUS_FLAG_OVERRIDDEN,
        false);
    bitstring_set_bit(
        &data.notificationParams.outOfRange.statusFlags,
        STATUS_FLAG_OUT_OF_SERVICE, false);
    Notification_Class_common_reporting_function(&data);
    if (data.ackRequired) {
        object->acked[transition] = false;
    }
}

/* The OUT_OF_RANGE state machine for one enrollment. */
static void bp_ee_update(bp_ee_t *object, uint32_t instance, uint32_t seconds)
{
    float value = 0.0f;
    uint8_t target;
    float limit;

    if (object->notification_class >= BACNET_MAX_INSTANCE) {
        return; /* not configured */
    }
    if (!bp_ee_monitored_value(object, &value)) {
        return;
    }
    /* the only exit from an off-normal state is to NORMAL (ASHRAE 135
       13.3.6): from HIGH_LIMIT once the value drops more than the deadband
       below the high limit, from LOW_LIMIT once it rises more than the
       deadband above the low limit. A value stable in its current state
       resets the pending time delay. */
    switch (object->event_state) {
        case EVENT_STATE_HIGH_LIMIT:
            if (value < object->high_limit - object->deadband) {
                target = EVENT_STATE_NORMAL;
                limit = value;
            } else {
                object->pending_to = EVENT_STATE_HIGH_LIMIT;
                object->pending_elapsed = 0;
                return;
            }
            break;
        case EVENT_STATE_LOW_LIMIT:
            if (value > object->low_limit + object->deadband) {
                target = EVENT_STATE_NORMAL;
                limit = value;
            } else {
                object->pending_to = EVENT_STATE_LOW_LIMIT;
                object->pending_elapsed = 0;
                return;
            }
            break;
        default: /* NORMAL */
            if (value > object->high_limit) {
                target = EVENT_STATE_HIGH_LIMIT;
                limit = object->high_limit;
            } else if (value < object->low_limit) {
                target = EVENT_STATE_LOW_LIMIT;
                limit = object->low_limit;
            } else {
                object->pending_to = EVENT_STATE_NORMAL;
                object->pending_elapsed = 0;
                return;
            }
            break;
    }
    /* a candidate transition must persist for the time delay */
    if (object->pending_to != target) {
        object->pending_to = target;
        object->pending_elapsed = 0;
    }
    object->pending_elapsed += seconds;
    if (object->pending_elapsed < object->time_delay) {
        return;
    }
    {
        uint8_t from = object->event_state;
        uint8_t to = target;
        uint8_t enable_bit = to == EVENT_STATE_NORMAL ? 4 : 1;
        object->event_state = to;
        object->pending_elapsed = 0;
        if (object->event_enable & enable_bit) {
            bp_ee_notify(object, instance, from, to, value, limit);
        }
    }
}

void bp_ee_task(uint32_t seconds)
{
    unsigned i;

    if (!bp_state.server_enabled) {
        return;
    }
    for (i = 0; i < BP_EE_MAX; i++) {
        if (bp_ee[i].used) {
            bp_ee_update(&bp_ee[i], i, seconds);
        }
    }
}

#endif /* INTRINSIC_REPORTING */
