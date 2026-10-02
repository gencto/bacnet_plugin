/*
 * bacnet_plugin - Schedule and Calendar objects of the server and the
 * writes objects of the server make themselves.
 *
 * Schedules, Loops, Timers and Channels write to other objects through an
 * internal WriteProperty callback: bp_internal_write() marks those writes
 * (BP_FLAG_INTERNAL of BP_EVENT_WRITE) and reports them also while the
 * application writes locally.
 *
 * bacnet-stack writes the members of a Schedule with priority 16 and offers
 * no way to change Priority_For_Writing: the wrappers of the object table
 * keep a priority per schedule, report it as Priority_For_Writing and apply
 * it to the writes of that schedule.
 *
 * bacnet-stack writes a whole Exception_Schedule with as many elements as
 * it had before, and refuses every Date_List of a Calendar (it decodes the
 * list as an application value first): the wrappers resize the exception
 * schedule to the written elements and decode date lists themselves.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdint.h>
#include <string.h>

#include "bacnet/bacdcode.h"
#include "bacnet/calendar_entry.h"
#include "bacnet/special_event.h"
#include "bacnet/basic/object/calendar.h"
#include "bacnet/basic/object/channel.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/object/loop.h"
#include "bacnet/basic/object/schedule.h"
#include "bacnet/basic/object/timer.h"
#include "bacnet/basic/sys/keylist.h"

#include "bp_internal.h"

/* instance -> Priority_For_Writing (stored in the data pointer) */
static OS_Keylist bp_schedule_priorities;
/* the schedule whose members are being written */
static uint32_t bp_schedule_current = BACNET_MAX_INSTANCE;

static uint8_t bp_schedule_priority(uint32_t instance)
{
    void *data;

    if (!bp_schedule_priorities) {
        return BACNET_MAX_PRIORITY;
    }
    data = Keylist_Data(bp_schedule_priorities, instance);
    return data ? (uint8_t)(uintptr_t)data : BACNET_MAX_PRIORITY;
}

static bool bp_internal_write(BACNET_WRITE_PROPERTY_DATA *wp_data)
{
    bool suppress = bp_state.suppress_write_events;
    bool internal = bp_state.internal_write;
    uint32_t schedule = bp_schedule_current;
    bool status;

    if (schedule < BACNET_MAX_INSTANCE) {
        wp_data->priority = bp_schedule_priority(schedule);
    }
    /* reported even while the application writes the triggering value;
       writes the target makes in turn (a Channel) are not the schedule's */
    bp_state.suppress_write_events = false;
    bp_state.internal_write = true;
    bp_schedule_current = BACNET_MAX_INSTANCE;
    status = Device_Write_Property(wp_data);
    bp_schedule_current = schedule;
    bp_state.internal_write = internal;
    bp_state.suppress_write_events = suppress;
    return status;
}

void bp_internal_writes_init(void)
{
    Schedule_Write_Property_Internal_Callback_Set(bp_internal_write);
    Loop_Write_Property_Internal_Callback_Set(bp_internal_write);
#if (BACNET_PROTOCOL_REVISION >= 14)
    Channel_Write_Property_Internal_Callback_Set(bp_internal_write);
#endif
#if (BACNET_PROTOCOL_REVISION >= 17)
    Timer_Write_Property_Internal_Callback_Set(bp_internal_write);
#endif
}

bool bp_schedule_priority_set(uint32_t instance, uint8_t priority)
{
    if (!Schedule_Valid_Instance(instance) || priority < BACNET_MIN_PRIORITY ||
        priority > BACNET_MAX_PRIORITY) {
        return false;
    }
    if (!bp_schedule_priorities) {
        bp_schedule_priorities = Keylist_Create();
        if (!bp_schedule_priorities) {
            return false;
        }
    }
    (void)Keylist_Data_Delete(bp_schedule_priorities, instance);
    if (priority == BACNET_MAX_PRIORITY) {
        return true;
    }
    return Keylist_Data_Add(
               bp_schedule_priorities, instance,
               (void *)(uintptr_t)priority) >= 0;
}

/* ---- object table wrappers ------------------------------------------ */

/* Schedule_Object_Name() checks the UTF-8 of the string it is about to fill
   before filling it: callers pass uninitialized strings (Who-Has, the
   ReadProperty of Object_Name), so it reads past them. */
bool bp_schedule_object_name(
    uint32_t object_instance, BACNET_CHARACTER_STRING *object_name)
{
    if (!object_name) {
        return false;
    }
    characterstring_init_ansi(object_name, "");
    return Schedule_Object_Name(object_instance, object_name);
}

int bp_schedule_read_property(BACNET_READ_PROPERTY_DATA *rpdata)
{
    if (rpdata && rpdata->object_property == PROP_OBJECT_NAME &&
        rpdata->application_data && rpdata->application_data_len > 0 &&
        Schedule_Valid_Instance(rpdata->object_instance)) {
        BACNET_CHARACTER_STRING name;

        if (rpdata->array_index != BACNET_ARRAY_ALL) {
            rpdata->error_class = ERROR_CLASS_PROPERTY;
            rpdata->error_code = ERROR_CODE_PROPERTY_IS_NOT_AN_ARRAY;
            return BACNET_STATUS_ERROR;
        }
        if (!bp_schedule_object_name(rpdata->object_instance, &name)) {
            rpdata->error_class = ERROR_CLASS_OBJECT;
            rpdata->error_code = ERROR_CODE_UNKNOWN_OBJECT;
            return BACNET_STATUS_ERROR;
        }
        return encode_application_character_string(
            rpdata->application_data, &name);
    }
    if (rpdata && rpdata->object_property == PROP_PRIORITY_FOR_WRITING &&
        rpdata->application_data && rpdata->application_data_len > 0 &&
        Schedule_Valid_Instance(rpdata->object_instance)) {
        if (rpdata->array_index != BACNET_ARRAY_ALL) {
            rpdata->error_class = ERROR_CLASS_PROPERTY;
            rpdata->error_code = ERROR_CODE_PROPERTY_IS_NOT_AN_ARRAY;
            return BACNET_STATUS_ERROR;
        }
        return encode_application_unsigned(
            rpdata->application_data,
            bp_schedule_priority(rpdata->object_instance));
    }
    return Schedule_Read_Property(rpdata);
}

/* Resizes Exception_Schedule to the number of elements of a write of the
   whole array. */
static bool bp_schedule_resize_exceptions(BACNET_WRITE_PROPERTY_DATA *wp_data)
{
    BACNET_WRITE_PROPERTY_DATA resize;
    int offset = 0;
    int len;
    unsigned count = 0;

    while (offset < wp_data->application_data_len) {
        len = bacnet_special_event_entry_decode(
            &wp_data->application_data[offset],
            wp_data->application_data_len - offset, NULL, NULL, NULL);
        if (len <= 0) {
            wp_data->error_class = ERROR_CLASS_PROPERTY;
            wp_data->error_code = ERROR_CODE_INVALID_DATA_TYPE;
            return false;
        }
        offset += len;
        count++;
    }
    if (count > BACNET_EXCEPTION_SCHEDULE_SIZE) {
        wp_data->error_class = ERROR_CLASS_RESOURCES;
        wp_data->error_code = ERROR_CODE_NO_SPACE_TO_WRITE_PROPERTY;
        return false;
    }
    resize = *wp_data;
    resize.array_index = 0;
    resize.application_data_len =
        encode_application_unsigned(resize.application_data, count);
    if (!Schedule_Write_Property(&resize)) {
        wp_data->error_class = resize.error_class;
        wp_data->error_code = resize.error_code;
        return false;
    }
    return true;
}

bool bp_schedule_write_property(BACNET_WRITE_PROPERTY_DATA *wp_data)
{
    uint32_t previous = bp_schedule_current;
    bool status;

    if (wp_data && wp_data->object_property == PROP_EXCEPTION_SCHEDULE &&
        wp_data->array_index == BACNET_ARRAY_ALL &&
        Schedule_Valid_Instance(wp_data->object_instance) &&
        !bp_schedule_resize_exceptions(wp_data)) {
        return false;
    }
    /* a write of Present_Value writes the members */
    bp_schedule_current = wp_data ? wp_data->object_instance : previous;
    status = Schedule_Write_Property(wp_data);
    bp_schedule_current = previous;
    return status;
}

bool bp_calendar_write_property(BACNET_WRITE_PROPERTY_DATA *wp_data)
{
    BACNET_CALENDAR_ENTRY entry;
    int offset;
    int len;

    if (!wp_data || wp_data->object_property != PROP_DATE_LIST) {
        return Calendar_Write_Property(wp_data);
    }
    if (!Calendar_Valid_Instance(wp_data->object_instance)) {
        wp_data->error_class = ERROR_CLASS_OBJECT;
        wp_data->error_code = ERROR_CODE_UNKNOWN_OBJECT;
        return false;
    }
    if (wp_data->array_index != BACNET_ARRAY_ALL) {
        wp_data->error_class = ERROR_CLASS_PROPERTY;
        wp_data->error_code = ERROR_CODE_PROPERTY_IS_NOT_AN_ARRAY;
        return false;
    }
    /* a malformed list leaves the dates unchanged */
    for (offset = 0; offset < wp_data->application_data_len; offset += len) {
        len = bacnet_calendar_entry_decode(
            &wp_data->application_data[offset],
            (uint32_t)(wp_data->application_data_len - offset), &entry);
        if (len <= 0) {
            wp_data->error_class = ERROR_CLASS_PROPERTY;
            wp_data->error_code = ERROR_CODE_INVALID_DATA_TYPE;
            return false;
        }
    }
    (void)Calendar_Date_List_Delete_All(wp_data->object_instance);
    for (offset = 0; offset < wp_data->application_data_len; offset += len) {
        len = bacnet_calendar_entry_decode(
            &wp_data->application_data[offset],
            (uint32_t)(wp_data->application_data_len - offset), &entry);
        if (!Calendar_Date_List_Add(wp_data->object_instance, &entry)) {
            wp_data->error_class = ERROR_CLASS_RESOURCES;
            wp_data->error_code = ERROR_CODE_NO_SPACE_TO_WRITE_PROPERTY;
            return false;
        }
    }
    return true;
}

void bp_schedule_timer(uint32_t object_instance, uint16_t milliseconds)
{
    uint32_t previous = bp_schedule_current;

    bp_schedule_current = object_instance;
    Schedule_Timer(object_instance, milliseconds);
    bp_schedule_current = previous;
}

bool bp_schedule_delete(uint32_t object_instance)
{
    if (!Schedule_Delete(object_instance)) {
        return false;
    }
    if (bp_schedule_priorities) {
        (void)Keylist_Data_Delete(bp_schedule_priorities, object_instance);
    }
    return true;
}
