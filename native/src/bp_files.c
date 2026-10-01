/*
 * bacnet_plugin - File objects of the server with their content in memory.
 *
 * bacnet-stack keeps the properties of File objects and asks callbacks for
 * the content, by path name. Every File object created here gets the path
 * name "bp-file:<instance>" and a buffer (the object's create context).
 * bacnet-stack reports the path name as Description and lets clients
 * change it by writing Description: the wrappers of the object table keep
 * the description apart, and report the time of the last change as
 * Modification_Date.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bacnet/apdu.h"
#include "bacnet/awf.h"
#include "bacnet/bacapp.h"
#include "bacnet/bacdcode.h"
#include "bacnet/bacstr.h"
#include "bacnet/datetime.h"
#include "bacnet/rp.h"
#include "bacnet/wp.h"
#include "bacnet/basic/object/bacfile.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/services.h"
#include "bacnet/basic/tsm/tsm.h"

#include "bp_internal.h"

#define BP_FILE_PREFIX "bp-file:"
/* positions of AtomicReadFile and AtomicWriteFile are signed 32 bit */
#define BP_FILE_MAX_SIZE 0x7FFFFFFFu

typedef struct {
    char pathname[24];
    uint8_t *data;
    uint32_t len;
    uint32_t cap;
    BACNET_DATE_TIME modified;
} bp_file_t;

static bp_file_t *bp_file(uint32_t instance)
{
    return bacfile_valid_instance(instance)
        ? (bp_file_t *)bacfile_create_context_get(instance)
        : NULL;
}

static bp_file_t *bp_file_by_path(const char *pathname, uint32_t *instance)
{
    const size_t prefix = sizeof(BP_FILE_PREFIX) - 1;
    unsigned long number;
    char *end = NULL;

    if (!pathname || strncmp(pathname, BP_FILE_PREFIX, prefix) != 0) {
        return NULL;
    }
    number = strtoul(pathname + prefix, &end, 10);
    if (!end || *end || number >= BACNET_MAX_INSTANCE) {
        return NULL;
    }
    if (instance) {
        *instance = (uint32_t)number;
    }
    return bp_file((uint32_t)number);
}

static void bp_file_modified(bp_file_t *file, uint32_t instance)
{
    Device_getCurrentDateTime(&file->modified);
    /* the content changed since it was archived */
    (void)bacfile_archive_set(instance, false);
}

static bool bp_file_resize(bp_file_t *file, uint64_t size)
{
    if (size > BP_FILE_MAX_SIZE) {
        return false;
    }
    if (size > file->cap) {
        uint64_t cap = file->cap ? file->cap : 256;
        uint8_t *data;

        while (cap < size) {
            cap *= 2;
        }
        if (cap > BP_FILE_MAX_SIZE) {
            cap = BP_FILE_MAX_SIZE;
        }
        data = (uint8_t *)realloc(file->data, (size_t)cap);
        if (!data) {
            return false;
        }
        file->data = data;
        file->cap = (uint32_t)cap;
    }
    if (size > file->len) {
        memset(&file->data[file->len], 0, (size_t)(size - file->len));
    }
    file->len = (uint32_t)size;
    return true;
}

/* ---- bacfile callbacks ---------------------------------------------- */

static size_t bp_file_size(const char *pathname)
{
    bp_file_t *file = bp_file_by_path(pathname, NULL);

    return file ? file->len : 0;
}

static bool bp_file_size_set(const char *pathname, size_t size)
{
    uint32_t instance = 0;
    bp_file_t *file = bp_file_by_path(pathname, &instance);

    if (!file || !bp_file_resize(file, size)) {
        return false;
    }
    bp_file_modified(file, instance);
    return true;
}

static size_t bp_file_read_stream(
    const char *pathname, int32_t start, uint8_t *buffer, size_t size)
{
    bp_file_t *file = bp_file_by_path(pathname, NULL);
    size_t count;

    if (!file || start < 0 || (uint32_t)start >= file->len) {
        return 0;
    }
    count = file->len - (uint32_t)start;
    if (count > size) {
        count = size;
    }
    memcpy(buffer, &file->data[start], count);
    return count;
}

static size_t bp_file_write_stream(
    const char *pathname, int32_t start, const uint8_t *buffer, size_t size)
{
    uint32_t instance = 0;
    bp_file_t *file = bp_file_by_path(pathname, &instance);
    uint64_t end;

    if (!file || size == 0) {
        return 0;
    }
    if (start == -1) {
        /* append */
        start = (int32_t)file->len;
    }
    if (start < 0) {
        return 0;
    }
    end = (uint64_t)start + size;
    if (end > file->len && !bp_file_resize(file, end)) {
        return 0;
    }
    memcpy(&file->data[start], buffer, size);
    bp_file_modified(file, instance);
    return size;
}

void bp_files_init(void)
{
    bacfile_file_size_callback_set(bp_file_size);
    bacfile_file_size_set_callback_set(bp_file_size_set);
    bacfile_read_stream_data_callback_set(bp_file_read_stream);
    bacfile_write_stream_data_callback_set(bp_file_write_stream);
}

/* ---- object table wrappers ------------------------------------------ */

uint32_t bp_file_create(uint32_t object_instance)
{
    uint32_t instance = bacfile_create(object_instance);
    bp_file_t *file;

    if (instance >= BACNET_MAX_INSTANCE || bp_file(instance)) {
        return instance;
    }
    file = (bp_file_t *)calloc(1, sizeof(*file));
    if (!file) {
        (void)bacfile_delete(instance);
        return BACNET_MAX_INSTANCE;
    }
    snprintf(
        file->pathname, sizeof(file->pathname), BP_FILE_PREFIX "%lu",
        (unsigned long)instance);
    Device_getCurrentDateTime(&file->modified);
    /* bacnet-stack keeps the pointer: file lives until the deletion */
    (void)bacfile_pathname_set(instance, file->pathname);
    bacfile_create_context_set(instance, file);
    return instance;
}

bool bp_file_delete(uint32_t object_instance)
{
    bp_file_t *file = bp_file(object_instance);

    if (!bacfile_delete(object_instance)) {
        return false;
    }
    if (file) {
        free(file->data);
        free(file);
    }
    bp_string_remove(
        bp_string_key(OBJECT_FILE, object_instance, BP_STRING_FILE_TYPE));
    return true;
}

static const char *bp_file_description(uint32_t instance)
{
    bp_string_entry_t *entry = bp_string_slot(
        bp_string_key(OBJECT_FILE, instance, BP_STRING_DESCRIPTION), false);

    return entry && entry->value ? entry->value : "";
}

int bp_file_read_property(BACNET_READ_PROPERTY_DATA *rpdata)
{
    BACNET_CHARACTER_STRING text;
    bp_file_t *file;
    int len;

    if (!rpdata || !rpdata->application_data ||
        rpdata->application_data_len <= 0) {
        return 0;
    }
    file = bp_file(rpdata->object_instance);
    switch (rpdata->object_property) {
        case PROP_DESCRIPTION:
            if (!characterstring_init_ansi(
                    &text, bp_file_description(rpdata->object_instance))) {
                (void)characterstring_init_ansi(&text, "");
            }
            len = encode_application_character_string(NULL, &text);
            if (len > rpdata->application_data_len) {
                rpdata->error_class = ERROR_CLASS_SERVICES;
                rpdata->error_code = ERROR_CODE_ABORT_SEGMENTATION_NOT_SUPPORTED;
                return BACNET_STATUS_ABORT;
            }
            return encode_application_character_string(
                rpdata->application_data, &text);
        case PROP_MODIFICATION_DATE:
            if (file) {
                return bacapp_encode_datetime(
                    rpdata->application_data, &file->modified);
            }
            break;
        default:
            break;
    }
    return bacfile_read_property(rpdata);
}

bool bp_file_write_property(BACNET_WRITE_PROPERTY_DATA *wp_data)
{
    BACNET_APPLICATION_DATA_VALUE value;
    char text[MAX_CHARACTER_STRING_BYTES + 1];
    char *previous = NULL;
    int len;

    if (!wp_data || wp_data->object_property != PROP_DESCRIPTION) {
        return bacfile_write_property(wp_data);
    }
    if (!bacfile_valid_instance(wp_data->object_instance)) {
        wp_data->error_class = ERROR_CLASS_OBJECT;
        wp_data->error_code = ERROR_CODE_UNKNOWN_OBJECT;
        return false;
    }
    if (wp_data->array_index != BACNET_ARRAY_ALL) {
        wp_data->error_class = ERROR_CLASS_PROPERTY;
        wp_data->error_code = ERROR_CODE_PROPERTY_IS_NOT_AN_ARRAY;
        return false;
    }
    memset(&value, 0, sizeof(value));
    len = bacapp_decode_application_data(
        wp_data->application_data, wp_data->application_data_len, &value);
    if (len < 0) {
        wp_data->error_class = ERROR_CLASS_PROPERTY;
        wp_data->error_code = ERROR_CODE_VALUE_OUT_OF_RANGE;
        return false;
    }
    if (!write_property_type_valid(
            wp_data, &value, BACNET_APPLICATION_TAG_CHARACTER_STRING)) {
        return false;
    }
    if (bacfile_read_only(wp_data->object_instance)) {
        wp_data->error_class = ERROR_CLASS_PROPERTY;
        wp_data->error_code = ERROR_CODE_WRITE_ACCESS_DENIED;
        return false;
    }
    if (!characterstring_utf8_valid(&value.type.Character_String) ||
        !characterstring_ansi_copy(
            text, sizeof(text), &value.type.Character_String) ||
        strlen(text) != characterstring_length(&value.type.Character_String)) {
        wp_data->error_class = ERROR_CLASS_PROPERTY;
        wp_data->error_code = ERROR_CODE_VALUE_OUT_OF_RANGE;
        return false;
    }
    if (!bp_string_store(
            bp_string_key(
                OBJECT_FILE, wp_data->object_instance, BP_STRING_DESCRIPTION),
            text, &previous)) {
        wp_data->error_class = ERROR_CLASS_RESOURCES;
        wp_data->error_code = ERROR_CODE_NO_SPACE_TO_WRITE_PROPERTY;
        return false;
    }
    free(previous);
    return true;
}

/* the description is kept by bp_objects.c in the string table */
bool bp_file_description_set(uint32_t instance, const char *description)
{
    (void)description;
    return bacfile_valid_instance(instance);
}

/* ---- AtomicWriteFile ------------------------------------------------- */

void bp_on_atomic_write_file(
    uint8_t *request,
    uint16_t len,
    BACNET_ADDRESS *src,
    BACNET_CONFIRMED_SERVICE_DATA *service_data)
{
    BACNET_ATOMIC_WRITE_FILE_DATA data;
    uint8_t copy[MAX_APDU];
    int copy_len;
    bool decoded = false;

    memset(&data, 0, sizeof(data));
    if (len > 0 && !service_data->segmented_message &&
        awf_decode_service_request(request, len, &data) > 0) {
        decoded = true;
        /* an append (start position -1) is written at the end of the file,
           so the answer tells where, as the standard requires */
        if (data.object_type == OBJECT_FILE &&
            data.access == FILE_STREAM_ACCESS &&
            data.type.stream.fileStartPosition == -1 &&
            bp_file(data.object_instance)) {
            data.type.stream.fileStartPosition =
                (int32_t)bacfile_file_size(data.object_instance);
            copy_len = atomicwritefile_service_request_encode(
                copy, sizeof(copy), &data);
            if (copy_len > 0 && copy_len <= (int)sizeof(copy)) {
                request = copy;
                len = (uint16_t)copy_len;
            }
        }
    }
    memset(Handler_Transmit_Buffer, 0, 8);
    handler_atomic_write_file(request, len, src, service_data);
    if (decoded && bp_reply_pdu_type() == PDU_TYPE_COMPLEX_ACK) {
        bp_service_reported(
            SERVICE_CONFIRMED_ATOMIC_WRITE_FILE, request, len, src);
    }
}

/* ---- API --------------------------------------------------------------- */

BP_API int32_t bacnet_plugin_file_set_content(
    uint32_t instance, const uint8_t *data, uint32_t length)
{
    bp_file_t *file;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (length > 0 && !data) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    file = bp_file(instance);
    if (!file) {
        return BP_ERR_OBJECT;
    }
    file->len = 0;
    if (!bp_file_resize(file, length)) {
        return length > BP_FILE_MAX_SIZE ? BP_ERR_INVALID_ARGUMENT
                                         : BP_ERR_NO_MEMORY;
    }
    if (length) {
        memcpy(file->data, data, length);
    }
    bp_file_modified(file, instance);
    return BP_OK;
}

BP_API int64_t bacnet_plugin_file_get_content(
    uint32_t instance, uint32_t offset, uint8_t *buffer, uint32_t capacity)
{
    bp_file_t *file;
    uint32_t count;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (capacity > 0 && !buffer) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    file = bp_file(instance);
    if (!file) {
        return BP_ERR_OBJECT;
    }
    if (offset < file->len) {
        count = file->len - offset;
        if (count > capacity) {
            count = capacity;
        }
        memcpy(buffer, &file->data[offset], count);
    }
    return (int64_t)file->len;
}

BP_API int32_t bacnet_plugin_file_configure(
    uint32_t instance, const char *file_type, int32_t read_only)
{
    char *previous = NULL;
    char *stored;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (!bp_file(instance)) {
        return BP_ERR_OBJECT;
    }
    if (file_type) {
        if (strlen(file_type) > MAX_CHARACTER_STRING_BYTES) {
            return BP_ERR_INVALID_ARGUMENT;
        }
        /* bacnet-stack keeps the pointer */
        stored = bp_string_store(
            bp_string_key(OBJECT_FILE, instance, BP_STRING_FILE_TYPE),
            file_type, &previous);
        if (!stored) {
            return BP_ERR_NO_MEMORY;
        }
        (void)bacfile_file_type_set(instance, stored);
        free(previous);
    }
    if (read_only >= 0) {
        (void)bacfile_read_only_set(instance, read_only != 0);
    }
    return BP_OK;
}
