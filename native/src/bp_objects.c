/*
 * bacnet_plugin - local object properties (names, present values,
 * units, state texts) and local Read/WriteProperty.
 *
 * SPDX-License-Identifier: MIT
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "bacnet/bacstr.h"
#include "bacnet/basic/object/ai.h"
#include "bacnet/basic/object/ao.h"
#include "bacnet/basic/object/av.h"
#include "bacnet/basic/object/bacfile.h"
#include "bacnet/basic/object/calendar.h"
#include "bacnet/basic/object/channel.h"
#include "bacnet/basic/object/schedule.h"
#include "bacnet/basic/object/lo.h"
#include "bacnet/basic/object/blo.h"
#include "bacnet/basic/object/color_object.h"
#include "bacnet/basic/object/color_temperature.h"
#include "bacnet/basic/object/loop.h"
#include "bacnet/basic/object/timer.h"
#include "bacnet/basic/object/acc.h"
#include "bacnet/basic/object/averaging.h"
#include "bacnet/basic/object/lc.h"
#include "bacnet/basic/object/structured_view.h"
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

#include "bp_internal.h"

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
#if defined(INTRINSIC_REPORTING)
        case OBJECT_NOTIFICATION_CLASS:
            return description ? bp_nc_description_set : bp_nc_name_set;
        case OBJECT_EVENT_ENROLLMENT:
            return description ? bp_ee_description_set : bp_ee_name_set;
#endif
        case OBJECT_FILE:
            return description ? bp_file_description_set
                               : bacfile_object_name_set;
        case OBJECT_SCHEDULE:
            return description ? Schedule_Description_Set : Schedule_Name_Set;
        case OBJECT_CALENDAR:
            return description ? Calendar_Description_Set : Calendar_Name_Set;
        case OBJECT_TRENDLOG:
            return bp_tl_text_set;
#if (BACNET_PROTOCOL_REVISION >= 14)
        case OBJECT_CHANNEL:
            return description ? Channel_Description_Set : Channel_Name_Set;
#endif
        case OBJECT_LIGHTING_OUTPUT:
            return description ? Lighting_Output_Description_Set
                               : Lighting_Output_Name_Set;
        case OBJECT_BINARY_LIGHTING_OUTPUT:
            return description ? Binary_Lighting_Output_Description_Set
                               : Binary_Lighting_Output_Name_Set;
        case OBJECT_COLOR:
            return description ? Color_Description_Set : Color_Name_Set;
        case OBJECT_COLOR_TEMPERATURE:
            return description ? Color_Temperature_Description_Set
                               : Color_Temperature_Name_Set;
        case OBJECT_LOOP:
            return description ? Loop_Description_Set : Loop_Name_Set;
        case OBJECT_TIMER:
            return description ? Timer_Description_Set : Timer_Name_Set;
        case OBJECT_ACCUMULATOR:
            return description ? Accumulator_Description_Set
                               : Accumulator_Name_Set;
        case OBJECT_AVERAGING:
            return description ? Averaging_Description_Set : Averaging_Name_Set;
        case OBJECT_LOAD_CONTROL:
            return description ? Load_Control_Description_Set
                               : Load_Control_Name_Set;
        case OBJECT_STRUCTURED_VIEW:
            return description ? Structured_View_Description_Set
                               : Structured_View_Name_Set;
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

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!text) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    setter = bp_name_setter(object_type, slot == BP_STRING_DESCRIPTION);
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
    if (slot == BP_STRING_NAME) {
        Device_Inc_Database_Revision();
    }
    return BP_OK;
}

BP_API int32_t bacnet_plugin_object_set_name(
    uint16_t object_type, uint32_t instance, const char *name)
{
    return bp_object_set_text(object_type, instance, name, BP_STRING_NAME);
}

BP_API int32_t bacnet_plugin_object_set_description(
    uint16_t object_type, uint32_t instance, const char *description)
{
    return bp_object_set_text(
        object_type, instance, description, BP_STRING_DESCRIPTION);
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
            ok =
                !relinquish && Binary_Input_Present_Value_Set(instance, binary);
            break;
        case OBJECT_BINARY_OUTPUT:
            ok = relinquish
                ? Binary_Output_Present_Value_Relinquish(instance, prio)
                : Binary_Output_Present_Value_Set(instance, binary, prio);
            break;
        case OBJECT_BINARY_VALUE:
            ok =
                !relinquish && Binary_Value_Present_Value_Set(instance, binary);
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

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    switch (property) {
        case PROP_PRESENT_VALUE:
            return bp_set_present_value(object_type, instance, value, priority);
        case PROP_PRIORITY_FOR_WRITING:
            if (object_type != OBJECT_SCHEDULE) {
                return BP_ERR_UNSUPPORTED;
            }
            if (value < BACNET_MIN_PRIORITY || value > BACNET_MAX_PRIORITY) {
                return BP_ERR_INVALID_ARGUMENT;
            }
            return bp_schedule_priority_set(instance, (uint8_t)value)
                ? BP_OK
                : BP_ERR_OBJECT;
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

    if (!bp_state.initialized) {
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
    key = bp_string_key(object_type, instance, BP_STRING_STATE_TEXTS);
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

    if (!bp_state.initialized) {
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

    if (!bp_state.initialized) {
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

    if (!bp_state.initialized) {
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
    bp_state.suppress_write_events = true;
    ok = Device_Write_Property(&wp_data);
    bp_state.suppress_write_events = false;
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

    if (!bp_state.initialized) {
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
