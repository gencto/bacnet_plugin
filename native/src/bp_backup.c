/*
 * bacnet_plugin - backup and restore of the server (ASHRAE 135 clause
 * 19.1), driven by the application.
 *
 * bacnet-stack's own procedure (BACNET_BACKUP_RESTORE) writes every object
 * into the first configuration file and deletes all objects before a
 * restore, its File objects included. Here the application names the
 * configuration files (File objects of bp_files.c) and keeps their
 * content: ReinitializeDevice START_BACKUP, END_BACKUP, START_RESTORE,
 * END_RESTORE and ABORT_RESTORE change Backup_And_Restore_State and are
 * reported as BP_EVENT_SERVICE; the application prepares the files of a
 * backup (PREPARING_FOR_BACKUP until bacnet_plugin_backup_set_state()) and
 * applies them after a restore.
 *
 * SPDX-License-Identifier: MIT
 */
#include <string.h>

#include "bacnet/apdu.h"
#include "bacnet/bacdcode.h"
#include "bacnet/bacerror.h"
#include "bacnet/bacstr.h"
#include "bacnet/datetime.h"
#include "bacnet/npdu.h"
#include "bacnet/proplist.h"
#include "bacnet/rd.h"
#include "bacnet/timestamp.h"
#include "bacnet/basic/object/bacfile.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/services.h"
#include "bacnet/basic/tsm/tsm.h"

#include "bp_internal.h"

#define BP_BACKUP_MAX_FILES 16

static struct {
    bool enabled;
    /* the application prepares the files of a backup */
    bool prepare;
    /* the application applies the files of a restore */
    bool apply;
    uint8_t state;
    uint32_t files[BP_BACKUP_MAX_FILES];
    unsigned file_count;
    uint16_t failure_timeout;
    uint32_t idle_seconds;
    BACNET_TIMESTAMP last_restore_time;
} bp_backup;

static const int32_t bp_backup_properties[] = {
    PROP_CONFIGURATION_FILES,       PROP_LAST_RESTORE_TIME,
    PROP_BACKUP_FAILURE_TIMEOUT,    PROP_BACKUP_PREPARATION_TIME,
    PROP_RESTORE_PREPARATION_TIME,  PROP_RESTORE_COMPLETION_TIME,
    PROP_BACKUP_AND_RESTORE_STATE,  -1
};

static bool bp_backup_in_progress(void)
{
    return bp_backup.state != BACKUP_STATE_IDLE &&
        bp_backup.state != BACKUP_STATE_BACKUP_FAILURE &&
        bp_backup.state != BACKUP_STATE_RESTORE_FAILURE;
}

void bp_backup_activity(void)
{
    bp_backup.idle_seconds = 0;
}

void bp_backup_timer(uint32_t seconds)
{
    if (!bp_backup.enabled || !bp_backup_in_progress()) {
        return;
    }
    bp_backup.idle_seconds += seconds;
    if (bp_backup.failure_timeout > 0 &&
        bp_backup.idle_seconds >= bp_backup.failure_timeout) {
        /* the client stopped: leave the procedure */
        bp_backup.state = (bp_backup.state == BACKUP_STATE_PREPARING_FOR_BACKUP ||
                           bp_backup.state == BACKUP_STATE_PERFORMING_A_BACKUP)
            ? BACKUP_STATE_BACKUP_FAILURE
            : BACKUP_STATE_RESTORE_FAILURE;
        bp_log(2, "backup or restore timed out (state %u)", bp_backup.state);
    }
}

/* ---- ReinitializeDevice ------------------------------------------------ */

static void bp_backup_reply(
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_DATA *service_data,
    BACNET_ERROR_CLASS error_class,
    BACNET_ERROR_CODE error_code)
{
    BACNET_NPDU_DATA npdu_data;
    BACNET_ADDRESS my_address;
    int len;

    datalink_get_my_address(&my_address);
    npdu_encode_npdu_data(&npdu_data, false, service_data->priority);
    len = npdu_encode_pdu(
        &Handler_Transmit_Buffer[0], src, &my_address, &npdu_data);
    if (error_code == ERROR_CODE_SUCCESS) {
        len += encode_simple_ack(
            &Handler_Transmit_Buffer[len], service_data->invoke_id,
            SERVICE_CONFIRMED_REINITIALIZE_DEVICE);
    } else {
        len += bacerror_encode_apdu(
            &Handler_Transmit_Buffer[len], service_data->invoke_id,
            SERVICE_CONFIRMED_REINITIALIZE_DEVICE, error_class, error_code);
    }
    (void)datalink_send_pdu(src, &npdu_data, &Handler_Transmit_Buffer[0], len);
}

static bool bp_backup_password_ok(
    const BACNET_CHARACTER_STRING *password,
    BACNET_ERROR_CLASS *error_class,
    BACNET_ERROR_CODE *error_code)
{
    bp_string_entry_t *entry = bp_string_slot(
        bp_string_key(OBJECT_DEVICE, 0, BP_STRING_PASSWORD), false);
    const char *expected = entry && entry->value ? entry->value : "";

    if (!*expected) {
        return true;
    }
    if (characterstring_length(password) > 20) {
        *error_class = ERROR_CLASS_SERVICES;
        *error_code = ERROR_CODE_PARAMETER_OUT_OF_RANGE;
        return false;
    }
    if (!characterstring_ansi_same(password, expected)) {
        *error_class = ERROR_CLASS_SECURITY;
        *error_code = ERROR_CODE_PASSWORD_FAILURE;
        return false;
    }
    return true;
}

bool bp_backup_reinitialize(
    uint8_t *request,
    uint16_t len,
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_DATA *service_data)
{
    BACNET_REINITIALIZED_STATE state = BACNET_REINIT_IDLE;
    BACNET_CHARACTER_STRING password;
    BACNET_ERROR_CLASS error_class = ERROR_CLASS_DEVICE;
    BACNET_ERROR_CODE error_code = ERROR_CODE_SUCCESS;
    BACNET_DATE_TIME now;
    uint8_t copy[8];
    size_t copy_len;

    if (!bp_backup.enabled || service_data->segmented_message || len == 0) {
        return false;
    }
    characterstring_init_ansi(&password, "");
    if (rd_decode_service_request(request, len, &state, &password) < 0 ||
        state < BACNET_REINIT_STARTBACKUP ||
        state > BACNET_REINIT_ABORTRESTORE) {
        /* not a state of the procedure: bacnet-stack answers */
        return false;
    }
    if (!bp_backup_password_ok(&password, &error_class, &error_code)) {
        bp_backup_reply(src, service_data, error_class, error_code);
        return true;
    }
    switch (state) {
        case BACNET_REINIT_STARTBACKUP:
        case BACNET_REINIT_STARTRESTORE:
            if (bp_backup_in_progress()) {
                error_code = ERROR_CODE_CONFIGURATION_IN_PROGRESS;
                break;
            }
            if (state == BACNET_REINIT_STARTBACKUP) {
                bp_backup.state = bp_backup.prepare
                    ? BACKUP_STATE_PREPARING_FOR_BACKUP
                    : BACKUP_STATE_PERFORMING_A_BACKUP;
            } else {
                bp_backup.state = BACKUP_STATE_PERFORMING_A_RESTORE;
            }
            break;
        case BACNET_REINIT_ENDBACKUP:
            if (bp_backup.state == BACKUP_STATE_PREPARING_FOR_BACKUP ||
                bp_backup.state == BACKUP_STATE_PERFORMING_A_BACKUP) {
                bp_backup.state = BACKUP_STATE_IDLE;
            }
            break;
        case BACNET_REINIT_ENDRESTORE:
            if (bp_backup.state != BACKUP_STATE_PERFORMING_A_RESTORE) {
                error_code = ERROR_CODE_CONFIGURATION_IN_PROGRESS;
                break;
            }
            /* the application applies the files and reports the result
               with bacnet_plugin_backup_set_state() */
            if (!bp_backup.apply) {
                bp_backup.state = BACKUP_STATE_IDLE;
            }
            Device_getCurrentDateTime(&now);
            bacapp_timestamp_datetime_set(&bp_backup.last_restore_time, &now);
            break;
        default: /* ABORT_RESTORE */
            if (bp_backup.state == BACKUP_STATE_PREPARING_FOR_RESTORE ||
                bp_backup.state == BACKUP_STATE_PERFORMING_A_RESTORE) {
                bp_backup.state = BACKUP_STATE_IDLE;
            }
            break;
    }
    bp_backup_reply(src, service_data, error_class, error_code);
    if (error_code == ERROR_CODE_SUCCESS) {
        bp_backup.idle_seconds = 0;
        copy_len =
            reinitialize_device_request_encode(copy, sizeof(copy), state, NULL);
        bp_service_reported(
            SERVICE_CONFIRMED_REINITIALIZE_DEVICE, copy, (int)copy_len, src);
    }
    return true;
}

/* ---- Device object properties ----------------------------------------- */

static int bp_backup_read_files(BACNET_READ_PROPERTY_DATA *rpdata)
{
    uint8_t *apdu = rpdata->application_data;
    int len = 0;
    unsigned i;

    if (rpdata->array_index == 0) {
        return encode_application_unsigned(apdu, bp_backup.file_count);
    }
    if (rpdata->array_index == BACNET_ARRAY_ALL) {
        for (i = 0; i < bp_backup.file_count; i++) {
            if (len + 5 > rpdata->application_data_len) {
                rpdata->error_class = ERROR_CLASS_SERVICES;
                rpdata->error_code = ERROR_CODE_ABORT_SEGMENTATION_NOT_SUPPORTED;
                return BACNET_STATUS_ABORT;
            }
            len += encode_application_object_id(
                &apdu[len], OBJECT_FILE, bp_backup.files[i]);
        }
        return len;
    }
    if (rpdata->array_index > bp_backup.file_count) {
        rpdata->error_class = ERROR_CLASS_PROPERTY;
        rpdata->error_code = ERROR_CODE_INVALID_ARRAY_INDEX;
        return BACNET_STATUS_ERROR;
    }
    return encode_application_object_id(
        apdu, OBJECT_FILE, bp_backup.files[rpdata->array_index - 1]);
}

int bp_device_read_property(BACNET_READ_PROPERTY_DATA *rpdata)
{
    uint8_t *apdu;

    if (!bp_backup.enabled || !rpdata || !rpdata->application_data ||
        rpdata->application_data_len <= 0) {
        return Device_Read_Property_Local(rpdata);
    }
    apdu = rpdata->application_data;
    if (rpdata->object_property == PROP_CONFIGURATION_FILES) {
        return bp_backup_read_files(rpdata);
    }
    if (property_list_member(bp_backup_properties, rpdata->object_property) &&
        rpdata->array_index != BACNET_ARRAY_ALL) {
        rpdata->error_class = ERROR_CLASS_PROPERTY;
        rpdata->error_code = ERROR_CODE_PROPERTY_IS_NOT_AN_ARRAY;
        return BACNET_STATUS_ERROR;
    }
    switch (rpdata->object_property) {
        case PROP_LAST_RESTORE_TIME:
            return bacapp_encode_timestamp(apdu, &bp_backup.last_restore_time);
        case PROP_BACKUP_FAILURE_TIMEOUT:
            return encode_application_unsigned(apdu, bp_backup.failure_timeout);
        case PROP_BACKUP_PREPARATION_TIME:
        case PROP_RESTORE_PREPARATION_TIME:
        case PROP_RESTORE_COMPLETION_TIME:
            /* the server answers while it prepares and applies */
            return encode_application_unsigned(apdu, 0);
        case PROP_BACKUP_AND_RESTORE_STATE:
            return encode_application_enumerated(apdu, bp_backup.state);
        default:
            return Device_Read_Property_Local(rpdata);
    }
}

void bp_device_property_lists(
    const int32_t **required,
    const int32_t **optional,
    const int32_t **proprietary)
{
    /* the optional properties of the Device object and those of backup */
    static int32_t extended[128];
    static bool built;
    const int32_t *device_optional = NULL;
    unsigned count = 0;
    unsigned i;

    Device_Property_Lists(required, &device_optional, proprietary);
    if (!bp_backup.enabled) {
        if (optional) {
            *optional = device_optional;
        }
        return;
    }
    if (!built) {
        while (device_optional && device_optional[count] != -1 &&
               count < 128 - 8) {
            extended[count] = device_optional[count];
            count++;
        }
        for (i = 0; bp_backup_properties[i] != -1; i++) {
            extended[count++] = bp_backup_properties[i];
        }
        extended[count] = -1;
        built = true;
    }
    if (optional) {
        *optional = extended;
    }
}

/* ---- API --------------------------------------------------------------- */

BP_API int32_t bacnet_plugin_backup_configure(
    const uint32_t *files,
    uint32_t count,
    uint32_t flags,
    uint16_t failure_timeout)
{
    BACNET_DATE_TIME never;
    uint32_t i;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!bp_state.server_enabled) {
        return BP_ERR_SERVER_DISABLED;
    }
    if (count > BP_BACKUP_MAX_FILES || (count > 0 && !files)) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    for (i = 0; i < count; i++) {
        if (!bacfile_valid_instance(files[i])) {
            return BP_ERR_OBJECT;
        }
    }
    if (!bp_backup.enabled) {
        datetime_wildcard_set(&never);
        bacapp_timestamp_datetime_set(&bp_backup.last_restore_time, &never);
        bp_backup.state = BACKUP_STATE_IDLE;
    }
    memcpy(bp_backup.files, files, count * sizeof(files[0]));
    bp_backup.file_count = count;
    bp_backup.prepare = (flags & BP_BACKUP_PREPARE) != 0;
    bp_backup.apply = (flags & BP_BACKUP_APPLY) != 0;
    bp_backup.failure_timeout = failure_timeout;
    bp_backup.enabled = true;
    return BP_OK;
}

BP_API int32_t bacnet_plugin_backup_set_state(uint8_t state)
{
    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!bp_backup.enabled || state >= BACKUP_STATE_MAX) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    bp_backup.state = state;
    bp_backup.idle_seconds = 0;
    return BP_OK;
}

void bp_backup_reset(void)
{
    memset(&bp_backup, 0, sizeof(bp_backup));
}
