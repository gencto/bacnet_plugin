/*
 * bacnet_plugin - server side: local device, COV, event reporting and
 * object lifecycle.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdlib.h>
#include <string.h>

#include "bacnet/apdu.h"
#include "bacnet/basic/object/bv.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/object/msv.h"
#include "bacnet/basic/object/nc.h"
#include "bacnet/basic/services.h"
#include "bacnet/basic/tsm/tsm.h"

#include "bp_internal.h"

static bool bp_on_write_store(BACNET_WRITE_PROPERTY_DATA *wp_data)
{
    bp_event_header_t hdr;

    if (wp_data && wp_data->object_type == OBJECT_NOTIFICATION_CLASS &&
        wp_data->object_property == PROP_RECIPIENT_LIST) {
        bp_state.nc_rescan = true;
    }
    if (bp_state.suppress_write_events || !wp_data) {
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

static int bp_on_list_element(BACNET_LIST_ELEMENT_DATA *list_element)
{
    if (list_element &&
        list_element->object_type == OBJECT_NOTIFICATION_CLASS &&
        list_element->object_property == PROP_RECIPIENT_LIST) {
        bp_state.nc_rescan = true;
    }
    return BACNET_STATUS_OK;
}

/* Runs the event algorithms of the objects (intrinsic reporting) once per
   second and resolves the addresses of device recipients of the
   Notification Classes: every NC_RESCAN_RECIPIENTS_SECS and after the
   recipients changed. */
void bp_event_reporting(uint32_t seconds)
{
#if defined(INTRINSIC_REPORTING)
    uint32_t runs = seconds > 10 ? 10 : seconds;

    if (!bp_state.server_enabled) {
        return;
    }
    while (runs-- > 0) {
        Device_local_reporting();
    }
    bp_state.nc_rescan_elapsed += seconds;
    if (bp_state.nc_rescan ||
        bp_state.nc_rescan_elapsed >= NC_RESCAN_RECIPIENTS_SECS) {
        bp_state.nc_rescan = false;
        bp_state.nc_rescan_elapsed = 0;
        Notification_Class_find_recipient();
    }
#else
    (void)seconds;
#endif
}

void bp_cov_scan(uint32_t now)
{
    uint32_t budget;

    if (!bp_state.server_enabled) {
        return;
    }
    if ((uint32_t)(now - bp_state.cov_scan_last) <
        bp_state.cov_scan_interval_ms) {
        return;
    }
    bp_state.cov_scan_last = now;
    budget = bp_state.cov_scan_budget;
    /* run one complete detection/notification cycle (4 steps per
       subscription); handler_cov_task() only performs a single step */
    while (budget-- > 0) {
        if (handler_cov_fsm()) {
            break;
        }
    }
}

BP_API int32_t
bacnet_plugin_server_enable(uint32_t device_instance, const char *device_name)
{
    if (!bp_state.initialized) {
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
    if (!bp_state.server_enabled) {
        apdu_set_unconfirmed_handler(
            SERVICE_UNCONFIRMED_WHO_IS, handler_who_is);
        apdu_set_unconfirmed_handler(
            SERVICE_UNCONFIRMED_WHO_HAS, handler_who_has);
        apdu_set_unconfirmed_handler(
            SERVICE_UNCONFIRMED_TIME_SYNCHRONIZATION, handler_timesync);
        apdu_set_unconfirmed_handler(
            SERVICE_UNCONFIRMED_UTC_TIME_SYNCHRONIZATION, handler_timesync_utc);
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
            SERVICE_CONFIRMED_REINITIALIZE_DEVICE, handler_reinitialize_device);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_ADD_LIST_ELEMENT, handler_add_list_element);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_REMOVE_LIST_ELEMENT, handler_remove_list_element);
#if defined(INTRINSIC_REPORTING)
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_ACKNOWLEDGE_ALARM, handler_alarm_ack);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_GET_EVENT_INFORMATION,
            handler_get_event_information);
        apdu_set_confirmed_handler(
            SERVICE_CONFIRMED_GET_ALARM_SUMMARY, handler_get_alarm_summary);
#endif
        handler_cov_init();
        Device_Write_Property_Store_Callback_Set(bp_on_write_store);
        Device_Add_List_Element_Callback_Set(bp_on_list_element);
        Device_Remove_List_Element_Callback_Set(bp_on_list_element);
        bp_state.nc_rescan = true;
        bp_state.nc_rescan_elapsed = 0;
        bp_state.server_enabled = true;
    }
    Send_I_Am(&Handler_Transmit_Buffer[0]);
    return BP_OK;
}

BP_API int32_t
bacnet_plugin_device_set_string(uint32_t property, const char *value)
{
    char *previous = NULL;
    char *stored;
    size_t len;
    bool ok;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!value) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    /* some setters keep the pointer (vendor name): keep a stable copy */
    stored = bp_string_store(
        bp_string_key(OBJECT_DEVICE, property, BP_STRING_DEVICE), value,
        &previous);
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
        bp_string_entry_t *e = bp_string_slot(
            bp_string_key(OBJECT_DEVICE, property, BP_STRING_DEVICE), false);
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
    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    Device_Set_Vendor_Identifier(vendor_id);
    return BP_OK;
}

BP_API int32_t bacnet_plugin_send_i_am(void)
{
    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!bp_state.server_enabled) {
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

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!bp_state.server_enabled) {
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

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    memset(&data, 0, sizeof(data));
    data.object_type = (BACNET_OBJECT_TYPE)object_type;
    data.object_instance = instance;
    if (!Device_Delete_Object(&data)) {
        return BP_ERR_OBJECT;
    }
    bp_string_remove(bp_string_key(object_type, instance, BP_STRING_NAME));
    bp_string_remove(
        bp_string_key(object_type, instance, BP_STRING_DESCRIPTION));
    bp_string_remove(
        bp_string_key(object_type, instance, BP_STRING_STATE_TEXTS));
    return BP_OK;
}
