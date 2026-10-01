/*
 * bacnet_plugin - Trend Log objects of the server.
 *
 * bacnet-stack's Trend Log keeps eight static logs filled with test data
 * and cannot set Log_DeviceObjectProperty (WriteProperty decodes the
 * reference as an application value first). This implementation keeps the
 * logs the application created, each with a ring buffer of Buffer_Size
 * records: it polls a property of an object of this device every
 * Log_Interval, or records the values the application appends, and answers
 * ReadRange by position, sequence number and time.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bacnet/bacapp.h"
#include "bacnet/bacdcode.h"
#include "bacnet/bacdevobjpropref.h"
#include "bacnet/bacstr.h"
#include "bacnet/datetime.h"
#include "bacnet/readrange.h"
#include "bacnet/rp.h"
#include "bacnet/wp.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/sys/keylist.h"

#include "bp_internal.h"

#define BP_TL_DEFAULT_BUFFER 1000
#define BP_TL_MAX_BUFFER 100000
/* hundredths of a second */
#define BP_TL_DEFAULT_INTERVAL 6000

/* the choices of BACnetLogRecord logDatum */
enum {
    BP_DATUM_STATUS = 0,
    BP_DATUM_BOOLEAN = 1,
    BP_DATUM_REAL = 2,
    BP_DATUM_ENUMERATED = 3,
    BP_DATUM_UNSIGNED = 4,
    BP_DATUM_SIGNED = 5,
    BP_DATUM_BITSTRING = 6,
    BP_DATUM_NULL = 7,
    BP_DATUM_FAILURE = 8
};

typedef struct {
    BACNET_DATE_TIME timestamp;
    uint8_t datum;
    /* status flags bits (in-alarm 1, fault 2, overridden 4,
       out-of-service 8), 0xFF when not recorded */
    uint8_t status_flags;
    /* bits of a bitstring or log status */
    uint8_t bits_used;
    union {
        bool boolean;
        float real;
        uint32_t unsigned_value;
        int32_t signed_value;
        uint32_t bits;
        struct {
            uint16_t error_class;
            uint16_t error_code;
        } failure;
    } value;
} bp_tl_record_t;

typedef struct {
    bool enable;
    bool stop_when_full;
    bool has_source;
    bool was_enabled;
    uint32_t log_interval;
    uint32_t elapsed_ms;
    BACNET_DATE_TIME start_time;
    BACNET_DATE_TIME stop_time;
    BACNET_DEVICE_OBJECT_PROPERTY_REFERENCE source;
    bp_tl_record_t *records;
    uint32_t buffer_size;
    uint32_t first;
    uint32_t count;
    uint32_t total;
} bp_tl_t;

static OS_Keylist bp_tl_list;

static const int32_t bp_tl_required[] = {
    PROP_OBJECT_IDENTIFIER, PROP_OBJECT_NAME,   PROP_OBJECT_TYPE,
    PROP_ENABLE,            PROP_STOP_WHEN_FULL, PROP_BUFFER_SIZE,
    PROP_LOG_BUFFER,        PROP_RECORD_COUNT,  PROP_TOTAL_RECORD_COUNT,
    PROP_EVENT_STATE,       PROP_LOGGING_TYPE,  PROP_STATUS_FLAGS,
    -1
};

static const int32_t bp_tl_optional[] = { PROP_DESCRIPTION,
                                           PROP_START_TIME,
                                           PROP_STOP_TIME,
                                           PROP_LOG_DEVICE_OBJECT_PROPERTY,
                                           PROP_LOG_INTERVAL,
                                           -1 };

static const int32_t bp_tl_proprietary[] = { -1 };

static const int32_t bp_tl_writable[] = {
    PROP_OBJECT_NAME,  PROP_DESCRIPTION, PROP_ENABLE,
    PROP_STOP_WHEN_FULL, PROP_BUFFER_SIZE, PROP_RECORD_COUNT,
    PROP_START_TIME,   PROP_STOP_TIME,   PROP_LOG_DEVICE_OBJECT_PROPERTY,
    PROP_LOG_INTERVAL, -1
};

static bp_tl_t *bp_tl(uint32_t instance)
{
    return bp_tl_list ? (bp_tl_t *)Keylist_Data(bp_tl_list, instance) : NULL;
}

void bp_tl_init(void)
{
    if (!bp_tl_list) {
        bp_tl_list = Keylist_Create();
    }
}

bool bp_tl_valid_instance(uint32_t instance)
{
    return bp_tl(instance) != NULL;
}

unsigned bp_tl_count(void)
{
    return bp_tl_list ? (unsigned)Keylist_Count(bp_tl_list) : 0;
}

uint32_t bp_tl_index_to_instance(unsigned index)
{
    KEY key = BACNET_MAX_INSTANCE;

    if (bp_tl_list) {
        (void)Keylist_Index_Key(bp_tl_list, index, &key);
    }
    return key;
}

void bp_tl_property_lists(
    const int32_t **required,
    const int32_t **optional,
    const int32_t **proprietary)
{
    if (required) {
        *required = bp_tl_required;
    }
    if (optional) {
        *optional = bp_tl_optional;
    }
    if (proprietary) {
        *proprietary = bp_tl_proprietary;
    }
}

void bp_tl_writable_property_list(uint32_t instance, const int32_t **properties)
{
    (void)instance;
    if (properties) {
        *properties = bp_tl_writable;
    }
}

static const char *bp_tl_text(uint32_t instance, uint8_t slot)
{
    bp_string_entry_t *entry =
        bp_string_slot(bp_string_key(OBJECT_TRENDLOG, instance, slot), false);

    return entry ? entry->value : NULL;
}

bool bp_tl_object_name(uint32_t instance, BACNET_CHARACTER_STRING *name)
{
    char text[32];
    const char *stored;

    if (!bp_tl(instance)) {
        return false;
    }
    stored = bp_tl_text(instance, BP_STRING_NAME);
    if (stored) {
        return characterstring_init_ansi(name, stored);
    }
    snprintf(text, sizeof(text), "TREND LOG %lu", (unsigned long)instance);
    return characterstring_init_ansi(name, text);
}

/* the setters of bp_objects.c store the text in the string table */
bool bp_tl_text_set(uint32_t instance, const char *text)
{
    (void)text;
    return bp_tl(instance) != NULL;
}

/* ---- records ----------------------------------------------------------- */

static bool bp_tl_effective_enable(const bp_tl_t *log)
{
    BACNET_DATE_TIME now;

    if (!log->enable) {
        return false;
    }
    if (datetime_wildcard(&log->start_time) &&
        datetime_wildcard(&log->stop_time)) {
        return true;
    }
    Device_getCurrentDateTime(&now);
    if (!datetime_wildcard(&log->start_time) &&
        datetime_compare(&now, &log->start_time) < 0) {
        return false;
    }
    if (!datetime_wildcard(&log->stop_time) &&
        datetime_compare(&now, &log->stop_time) > 0) {
        return false;
    }
    return true;
}

static bp_tl_record_t *bp_tl_record(const bp_tl_t *log, uint32_t index)
{
    /* index 1 is the oldest record */
    return &log->records[(log->first + index - 1) % log->buffer_size];
}

static void bp_tl_insert(bp_tl_t *log, const bp_tl_record_t *record)
{
    if (!log->records || log->buffer_size == 0) {
        return;
    }
    if (log->count == log->buffer_size) {
        if (log->stop_when_full) {
            log->enable = false;
            return;
        }
        log->first = (log->first + 1) % log->buffer_size;
        log->count--;
    }
    log->records[(log->first + log->count) % log->buffer_size] = *record;
    log->count++;
    /* Total_Record_Count wraps from 2^32 - 1 to 1 */
    log->total = log->total == UINT32_MAX ? 1 : log->total + 1;
    if (log->count == log->buffer_size && log->stop_when_full) {
        log->enable = false;
    }
}

static void bp_tl_status(bp_tl_t *log, uint8_t status, bool value)
{
    bp_tl_record_t record;

    memset(&record, 0, sizeof(record));
    Device_getCurrentDateTime(&record.timestamp);
    record.datum = BP_DATUM_STATUS;
    record.status_flags = 0xFF;
    record.bits_used = 3;
    record.value.bits = value ? (1u << status) : 0;
    bp_tl_insert(log, &record);
}

static void bp_tl_purge(bp_tl_t *log)
{
    log->first = 0;
    log->count = 0;
    bp_tl_status(log, LOG_STATUS_BUFFER_PURGED, true);
}

/* Fills the datum of record from an application encoded value. */
static void bp_tl_datum(bp_tl_record_t *record, const uint8_t *data, int len)
{
    BACNET_APPLICATION_DATA_VALUE value;
    unsigned i;

    memset(&value, 0, sizeof(value));
    if (len <= 0 || bacapp_decode_application_data(data, len, &value) <= 0) {
        record->datum = BP_DATUM_FAILURE;
        record->value.failure.error_class = ERROR_CLASS_PROPERTY;
        record->value.failure.error_code = ERROR_CODE_INVALID_DATA_TYPE;
        return;
    }
    switch (value.tag) {
        case BACNET_APPLICATION_TAG_NULL:
            record->datum = BP_DATUM_NULL;
            break;
        case BACNET_APPLICATION_TAG_BOOLEAN:
            record->datum = BP_DATUM_BOOLEAN;
            record->value.boolean = value.type.Boolean;
            break;
        case BACNET_APPLICATION_TAG_REAL:
            record->datum = BP_DATUM_REAL;
            record->value.real = value.type.Real;
            break;
        case BACNET_APPLICATION_TAG_DOUBLE:
            record->datum = BP_DATUM_REAL;
            record->value.real = (float)value.type.Double;
            break;
        case BACNET_APPLICATION_TAG_ENUMERATED:
            record->datum = BP_DATUM_ENUMERATED;
            record->value.unsigned_value = value.type.Enumerated;
            break;
        case BACNET_APPLICATION_TAG_UNSIGNED_INT:
            record->datum = BP_DATUM_UNSIGNED;
            record->value.unsigned_value =
                value.type.Unsigned_Int > UINT32_MAX
                ? UINT32_MAX
                : (uint32_t)value.type.Unsigned_Int;
            break;
        case BACNET_APPLICATION_TAG_SIGNED_INT:
            record->datum = BP_DATUM_SIGNED;
            record->value.signed_value = value.type.Signed_Int;
            break;
        case BACNET_APPLICATION_TAG_BIT_STRING:
            if (bitstring_bits_used(&value.type.Bit_String) <= 32) {
                record->datum = BP_DATUM_BITSTRING;
                record->bits_used =
                    bitstring_bits_used(&value.type.Bit_String);
                record->value.bits = 0;
                for (i = 0; i < record->bits_used; i++) {
                    if (bitstring_bit(&value.type.Bit_String, (uint8_t)i)) {
                        record->value.bits |= 1u << i;
                    }
                }
                break;
            }
            /* fall through */
        default:
            record->datum = BP_DATUM_FAILURE;
            record->value.failure.error_class = ERROR_CLASS_PROPERTY;
            record->value.failure.error_code = ERROR_CODE_DATATYPE_NOT_SUPPORTED;
            break;
    }
}

/* Status_Flags of the logged object, 0xFF when it has none. */
static uint8_t bp_tl_source_status(const bp_tl_t *log)
{
    BACNET_READ_PROPERTY_DATA rpdata;
    BACNET_APPLICATION_DATA_VALUE value;
    uint8_t buffer[16];
    uint8_t flags = 0;
    unsigned i;
    int len;

    memset(&rpdata, 0, sizeof(rpdata));
    rpdata.object_type = log->source.objectIdentifier.type;
    rpdata.object_instance = log->source.objectIdentifier.instance;
    rpdata.object_property = PROP_STATUS_FLAGS;
    rpdata.array_index = BACNET_ARRAY_ALL;
    rpdata.application_data = buffer;
    rpdata.application_data_len = sizeof(buffer);
    len = Device_Read_Property(&rpdata);
    memset(&value, 0, sizeof(value));
    if (len <= 0 || bacapp_decode_application_data(buffer, len, &value) <= 0 ||
        value.tag != BACNET_APPLICATION_TAG_BIT_STRING) {
        return 0xFF;
    }
    for (i = 0; i < 4; i++) {
        if (bitstring_bit(&value.type.Bit_String, (uint8_t)i)) {
            flags |= (uint8_t)(1u << i);
        }
    }
    return flags;
}

static void bp_tl_sample(bp_tl_t *log)
{
    BACNET_READ_PROPERTY_DATA rpdata;
    bp_tl_record_t record;
    uint8_t buffer[MAX_APDU];
    int len;

    memset(&record, 0, sizeof(record));
    Device_getCurrentDateTime(&record.timestamp);
    memset(&rpdata, 0, sizeof(rpdata));
    rpdata.object_type = log->source.objectIdentifier.type;
    rpdata.object_instance = log->source.objectIdentifier.instance;
    rpdata.object_property = log->source.propertyIdentifier;
    rpdata.array_index = log->source.arrayIndex;
    rpdata.application_data = buffer;
    rpdata.application_data_len = sizeof(buffer);
    len = Device_Read_Property(&rpdata);
    if (len < 0) {
        record.datum = BP_DATUM_FAILURE;
        record.value.failure.error_class = (uint16_t)rpdata.error_class;
        record.value.failure.error_code = (uint16_t)rpdata.error_code;
        record.status_flags = 0xFF;
    } else {
        bp_tl_datum(&record, buffer, len);
        record.status_flags = bp_tl_source_status(log);
    }
    bp_tl_insert(log, &record);
}

void bp_tl_timer(uint32_t instance, uint16_t milliseconds)
{
    bp_tl_t *log = bp_tl(instance);
    uint32_t interval_ms;
    bool enabled;

    if (!log) {
        return;
    }
    enabled = bp_tl_effective_enable(log);
    if (log->was_enabled && !enabled) {
        bp_tl_status(log, LOG_STATUS_LOG_DISABLED, true);
    }
    if (!log->was_enabled && enabled) {
        /* sample at once */
        log->elapsed_ms = UINT32_MAX;
    }
    log->was_enabled = enabled;
    if (!enabled || !log->has_source) {
        return;
    }
    interval_ms = log->log_interval > UINT32_MAX / 10 ? UINT32_MAX
                                                       : log->log_interval * 10;
    if (log->elapsed_ms != UINT32_MAX) {
        log->elapsed_ms += milliseconds;
        if (log->elapsed_ms < interval_ms) {
            return;
        }
    }
    log->elapsed_ms = 0;
    bp_tl_sample(log);
}

/* ---- object lifecycle -------------------------------------------------- */

static bool bp_tl_buffer_resize(bp_tl_t *log, uint32_t size)
{
    bp_tl_record_t *records;

    if (size == 0 || size > BP_TL_MAX_BUFFER) {
        return false;
    }
    records = (bp_tl_record_t *)calloc(size, sizeof(*records));
    if (!records) {
        return false;
    }
    free(log->records);
    log->records = records;
    log->buffer_size = size;
    log->first = 0;
    log->count = 0;
    return true;
}

uint32_t bp_tl_create(uint32_t object_instance)
{
    bp_tl_t *log;

    bp_tl_init();
    if (!bp_tl_list || object_instance > BACNET_MAX_INSTANCE) {
        return BACNET_MAX_INSTANCE;
    }
    if (object_instance == BACNET_MAX_INSTANCE) {
        object_instance = Keylist_Next_Empty_Key(bp_tl_list, 1);
    }
    if (bp_tl(object_instance)) {
        return object_instance;
    }
    log = (bp_tl_t *)calloc(1, sizeof(*log));
    if (!log) {
        return BACNET_MAX_INSTANCE;
    }
    if (!bp_tl_buffer_resize(log, BP_TL_DEFAULT_BUFFER)) {
        free(log);
        return BACNET_MAX_INSTANCE;
    }
    log->log_interval = BP_TL_DEFAULT_INTERVAL;
    datetime_wildcard_set(&log->start_time);
    datetime_wildcard_set(&log->stop_time);
    if (Keylist_Data_Add(bp_tl_list, object_instance, log) < 0) {
        free(log->records);
        free(log);
        return BACNET_MAX_INSTANCE;
    }
    return object_instance;
}

bool bp_tl_delete(uint32_t object_instance)
{
    bp_tl_t *log;

    if (!bp_tl_list) {
        return false;
    }
    log = (bp_tl_t *)Keylist_Data_Delete(bp_tl_list, object_instance);
    if (!log) {
        return false;
    }
    free(log->records);
    free(log);
    return true;
}

/* ---- ReadProperty / WriteProperty -------------------------------------- */

static int bp_tl_encode_reference(uint8_t *apdu, const bp_tl_t *log)
{
    BACNET_DEVICE_OBJECT_PROPERTY_REFERENCE empty;

    if (log->has_source) {
        return bacapp_encode_device_obj_property_ref(apdu, &log->source);
    }
    /* no source: an empty reference to no object */
    memset(&empty, 0, sizeof(empty));
    empty.objectIdentifier.type = OBJECT_DEVICE;
    empty.objectIdentifier.instance = BACNET_MAX_INSTANCE;
    empty.propertyIdentifier = PROP_ALL;
    empty.arrayIndex = BACNET_ARRAY_ALL;
    empty.deviceIdentifier.type = BACNET_NO_DEV_TYPE;
    empty.deviceIdentifier.instance = BACNET_NO_DEV_ID;
    return bacapp_encode_device_obj_property_ref(apdu, &empty);
}

int bp_tl_read_property(BACNET_READ_PROPERTY_DATA *rpdata)
{
    BACNET_CHARACTER_STRING text;
    BACNET_BIT_STRING bits;
    const char *description;
    uint8_t *apdu;
    bp_tl_t *log;

    if (!rpdata || !rpdata->application_data ||
        rpdata->application_data_len <= 0) {
        return 0;
    }
    log = bp_tl(rpdata->object_instance);
    if (!log) {
        rpdata->error_class = ERROR_CLASS_OBJECT;
        rpdata->error_code = ERROR_CODE_UNKNOWN_OBJECT;
        return BACNET_STATUS_ERROR;
    }
    if (rpdata->array_index != BACNET_ARRAY_ALL &&
        rpdata->object_property != PROP_LOG_BUFFER) {
        rpdata->error_class = ERROR_CLASS_PROPERTY;
        rpdata->error_code = ERROR_CODE_PROPERTY_IS_NOT_AN_ARRAY;
        return BACNET_STATUS_ERROR;
    }
    apdu = rpdata->application_data;
    switch (rpdata->object_property) {
        case PROP_OBJECT_IDENTIFIER:
            return encode_application_object_id(
                apdu, OBJECT_TRENDLOG, rpdata->object_instance);
        case PROP_OBJECT_NAME:
            (void)bp_tl_object_name(rpdata->object_instance, &text);
            return encode_application_character_string(apdu, &text);
        case PROP_OBJECT_TYPE:
            return encode_application_enumerated(apdu, OBJECT_TRENDLOG);
        case PROP_DESCRIPTION:
            description =
                bp_tl_text(rpdata->object_instance, BP_STRING_DESCRIPTION);
            if (!characterstring_init_ansi(
                    &text, description ? description : "")) {
                (void)characterstring_init_ansi(&text, "");
            }
            return encode_application_character_string(apdu, &text);
        case PROP_ENABLE:
            return encode_application_boolean(apdu, log->enable);
        case PROP_STOP_WHEN_FULL:
            return encode_application_boolean(apdu, log->stop_when_full);
        case PROP_BUFFER_SIZE:
            return encode_application_unsigned(apdu, log->buffer_size);
        case PROP_LOG_BUFFER:
            /* only ReadRange reads the buffer */
            rpdata->error_class = ERROR_CLASS_PROPERTY;
            rpdata->error_code = ERROR_CODE_READ_ACCESS_DENIED;
            return BACNET_STATUS_ERROR;
        case PROP_RECORD_COUNT:
            return encode_application_unsigned(apdu, log->count);
        case PROP_TOTAL_RECORD_COUNT:
            return encode_application_unsigned(apdu, log->total);
        case PROP_EVENT_STATE:
            return encode_application_enumerated(apdu, EVENT_STATE_NORMAL);
        case PROP_LOGGING_TYPE:
            return encode_application_enumerated(apdu, LOGGING_TYPE_POLLED);
        case PROP_STATUS_FLAGS:
            bitstring_init(&bits);
            bitstring_set_bit(&bits, STATUS_FLAG_IN_ALARM, false);
            bitstring_set_bit(&bits, STATUS_FLAG_FAULT, false);
            bitstring_set_bit(&bits, STATUS_FLAG_OVERRIDDEN, false);
            bitstring_set_bit(&bits, STATUS_FLAG_OUT_OF_SERVICE, false);
            return encode_application_bitstring(apdu, &bits);
        case PROP_START_TIME:
            return bacapp_encode_datetime(apdu, &log->start_time);
        case PROP_STOP_TIME:
            return bacapp_encode_datetime(apdu, &log->stop_time);
        case PROP_LOG_DEVICE_OBJECT_PROPERTY:
            return bp_tl_encode_reference(apdu, log);
        case PROP_LOG_INTERVAL:
            return encode_application_unsigned(apdu, log->log_interval);
        default:
            rpdata->error_class = ERROR_CLASS_PROPERTY;
            rpdata->error_code = ERROR_CODE_UNKNOWN_PROPERTY;
            return BACNET_STATUS_ERROR;
    }
}

static bool bp_tl_write_error(
    BACNET_WRITE_PROPERTY_DATA *wp_data,
    BACNET_ERROR_CLASS error_class,
    BACNET_ERROR_CODE error_code)
{
    wp_data->error_class = error_class;
    wp_data->error_code = error_code;
    return false;
}

static bool bp_tl_write_text(
    BACNET_WRITE_PROPERTY_DATA *wp_data,
    const BACNET_APPLICATION_DATA_VALUE *value,
    uint8_t slot)
{
    char text[MAX_CHARACTER_STRING_BYTES + 1];
    BACNET_OBJECT_TYPE type;
    uint32_t instance;
    char *previous = NULL;

    if (value->tag != BACNET_APPLICATION_TAG_CHARACTER_STRING) {
        return bp_tl_write_error(
            wp_data, ERROR_CLASS_PROPERTY, ERROR_CODE_INVALID_DATA_TYPE);
    }
    if (!characterstring_utf8_valid(&value->type.Character_String) ||
        !characterstring_ansi_copy(
            text, sizeof(text), &value->type.Character_String) ||
        strlen(text) != characterstring_length(&value->type.Character_String) ||
        (slot == BP_STRING_NAME && text[0] == 0)) {
        return bp_tl_write_error(
            wp_data, ERROR_CLASS_PROPERTY, ERROR_CODE_VALUE_OUT_OF_RANGE);
    }
    if (slot == BP_STRING_NAME &&
        Device_Valid_Object_Name(
            &value->type.Character_String, &type, &instance) &&
        (type != OBJECT_TRENDLOG || instance != wp_data->object_instance)) {
        return bp_tl_write_error(
            wp_data, ERROR_CLASS_PROPERTY, ERROR_CODE_DUPLICATE_NAME);
    }
    if (!bp_string_store(
            bp_string_key(OBJECT_TRENDLOG, wp_data->object_instance, slot),
            text, &previous)) {
        return bp_tl_write_error(
            wp_data, ERROR_CLASS_RESOURCES,
            ERROR_CODE_NO_SPACE_TO_WRITE_PROPERTY);
    }
    free(previous);
    return true;
}

bool bp_tl_write_property(BACNET_WRITE_PROPERTY_DATA *wp_data)
{
    BACNET_APPLICATION_DATA_VALUE value;
    BACNET_DEVICE_OBJECT_PROPERTY_REFERENCE source;
    BACNET_DATE_TIME datetime;
    bp_tl_t *log;
    int len;

    if (!wp_data) {
        return false;
    }
    log = bp_tl(wp_data->object_instance);
    if (!log) {
        return bp_tl_write_error(
            wp_data, ERROR_CLASS_OBJECT, ERROR_CODE_UNKNOWN_OBJECT);
    }
    if (wp_data->array_index != BACNET_ARRAY_ALL) {
        return bp_tl_write_error(
            wp_data, ERROR_CLASS_PROPERTY, ERROR_CODE_PROPERTY_IS_NOT_AN_ARRAY);
    }
    switch (wp_data->object_property) {
        case PROP_LOG_DEVICE_OBJECT_PROPERTY:
            memset(&source, 0, sizeof(source));
            len = bacnet_device_object_property_reference_decode(
                wp_data->application_data, wp_data->application_data_len,
                &source);
            if (len <= 0 || len != wp_data->application_data_len) {
                return bp_tl_write_error(
                    wp_data, ERROR_CLASS_PROPERTY,
                    ERROR_CODE_INVALID_DATA_TYPE);
            }
            /* only objects of this device are polled */
            if (source.deviceIdentifier.type == OBJECT_DEVICE &&
                source.deviceIdentifier.instance !=
                    Device_Object_Instance_Number()) {
                return bp_tl_write_error(
                    wp_data, ERROR_CLASS_PROPERTY,
                    ERROR_CODE_OPTIONAL_FUNCTIONALITY_NOT_SUPPORTED);
            }
            if (log->has_source &&
                memcmp(&source, &log->source, sizeof(source)) != 0) {
                /* another property: the old records do not belong to it */
                bp_tl_purge(log);
            }
            log->source = source;
            log->has_source = true;
            log->elapsed_ms = UINT32_MAX;
            return true;
        case PROP_START_TIME:
        case PROP_STOP_TIME:
            len = bacnet_datetime_decode(
                wp_data->application_data, wp_data->application_data_len,
                &datetime);
            if (len <= 0) {
                return bp_tl_write_error(
                    wp_data, ERROR_CLASS_PROPERTY,
                    ERROR_CODE_INVALID_DATA_TYPE);
            }
            if (wp_data->object_property == PROP_START_TIME) {
                log->start_time = datetime;
            } else {
                log->stop_time = datetime;
            }
            return true;
        default:
            break;
    }
    memset(&value, 0, sizeof(value));
    len = bacapp_decode_application_data(
        wp_data->application_data, wp_data->application_data_len, &value);
    if (len <= 0) {
        return bp_tl_write_error(
            wp_data, ERROR_CLASS_PROPERTY, ERROR_CODE_INVALID_DATA_TYPE);
    }
    switch (wp_data->object_property) {
        case PROP_OBJECT_NAME:
            return bp_tl_write_text(wp_data, &value, BP_STRING_NAME);
        case PROP_DESCRIPTION:
            return bp_tl_write_text(wp_data, &value, BP_STRING_DESCRIPTION);
        case PROP_ENABLE:
            if (value.tag != BACNET_APPLICATION_TAG_BOOLEAN) {
                break;
            }
            if (value.type.Boolean && log->stop_when_full &&
                log->count == log->buffer_size) {
                return bp_tl_write_error(
                    wp_data, ERROR_CLASS_OBJECT, ERROR_CODE_LOG_BUFFER_FULL);
            }
            log->enable = value.type.Boolean;
            return true;
        case PROP_STOP_WHEN_FULL:
            if (value.tag != BACNET_APPLICATION_TAG_BOOLEAN) {
                break;
            }
            log->stop_when_full = value.type.Boolean;
            if (log->stop_when_full && log->count == log->buffer_size) {
                log->enable = false;
            }
            return true;
        case PROP_BUFFER_SIZE:
            if (value.tag != BACNET_APPLICATION_TAG_UNSIGNED_INT) {
                break;
            }
            /* only while the log is disabled, the records are lost */
            if (log->enable) {
                return bp_tl_write_error(
                    wp_data, ERROR_CLASS_PROPERTY,
                    ERROR_CODE_WRITE_ACCESS_DENIED);
            }
            if (value.type.Unsigned_Int == 0 ||
                value.type.Unsigned_Int > BP_TL_MAX_BUFFER) {
                return bp_tl_write_error(
                    wp_data, ERROR_CLASS_PROPERTY,
                    ERROR_CODE_VALUE_OUT_OF_RANGE);
            }
            if (!bp_tl_buffer_resize(
                    log, (uint32_t)value.type.Unsigned_Int)) {
                return bp_tl_write_error(
                    wp_data, ERROR_CLASS_RESOURCES,
                    ERROR_CODE_NO_SPACE_TO_WRITE_PROPERTY);
            }
            return true;
        case PROP_RECORD_COUNT:
            if (value.tag != BACNET_APPLICATION_TAG_UNSIGNED_INT) {
                break;
            }
            /* only 0: purges the buffer */
            if (value.type.Unsigned_Int != 0) {
                return bp_tl_write_error(
                    wp_data, ERROR_CLASS_PROPERTY,
                    ERROR_CODE_VALUE_OUT_OF_RANGE);
            }
            bp_tl_purge(log);
            return true;
        case PROP_LOG_INTERVAL:
            if (value.tag != BACNET_APPLICATION_TAG_UNSIGNED_INT) {
                break;
            }
            /* 0 would mean change of value logging */
            if (value.type.Unsigned_Int == 0 ||
                value.type.Unsigned_Int > UINT32_MAX) {
                return bp_tl_write_error(
                    wp_data, ERROR_CLASS_PROPERTY,
                    ERROR_CODE_OPTIONAL_FUNCTIONALITY_NOT_SUPPORTED);
            }
            log->log_interval = (uint32_t)value.type.Unsigned_Int;
            return true;
        default:
            if (property_lists_member(
                    bp_tl_required, bp_tl_optional, bp_tl_proprietary,
                    wp_data->object_property)) {
                return bp_tl_write_error(
                    wp_data, ERROR_CLASS_PROPERTY,
                    ERROR_CODE_WRITE_ACCESS_DENIED);
            }
            return bp_tl_write_error(
                wp_data, ERROR_CLASS_PROPERTY, ERROR_CODE_UNKNOWN_PROPERTY);
    }
    return bp_tl_write_error(
        wp_data, ERROR_CLASS_PROPERTY, ERROR_CODE_INVALID_DATA_TYPE);
}

/* ---- ReadRange --------------------------------------------------------- */

static int bp_tl_encode_record(uint8_t *apdu, const bp_tl_record_t *record)
{
    BACNET_BIT_STRING bits;
    int len = 0;
    unsigned i;

    len += encode_opening_tag(apdu ? &apdu[len] : NULL, 0);
    len += bacapp_encode_datetime(apdu ? &apdu[len] : NULL, &record->timestamp);
    len += encode_closing_tag(apdu ? &apdu[len] : NULL, 0);
    len += encode_opening_tag(apdu ? &apdu[len] : NULL, 1);
    switch (record->datum) {
        case BP_DATUM_STATUS:
        case BP_DATUM_BITSTRING:
            bitstring_init(&bits);
            for (i = 0; i < record->bits_used; i++) {
                bitstring_set_bit(
                    &bits, (uint8_t)i, (record->value.bits >> i) & 1u);
            }
            len += encode_context_bitstring(
                apdu ? &apdu[len] : NULL, record->datum, &bits);
            break;
        case BP_DATUM_BOOLEAN:
            len += encode_context_boolean(
                apdu ? &apdu[len] : NULL, BP_DATUM_BOOLEAN,
                record->value.boolean);
            break;
        case BP_DATUM_REAL:
            len += encode_context_real(
                apdu ? &apdu[len] : NULL, BP_DATUM_REAL, record->value.real);
            break;
        case BP_DATUM_ENUMERATED:
            len += encode_context_enumerated(
                apdu ? &apdu[len] : NULL, BP_DATUM_ENUMERATED,
                record->value.unsigned_value);
            break;
        case BP_DATUM_UNSIGNED:
            len += encode_context_unsigned(
                apdu ? &apdu[len] : NULL, BP_DATUM_UNSIGNED,
                record->value.unsigned_value);
            break;
        case BP_DATUM_SIGNED:
            len += encode_context_signed(
                apdu ? &apdu[len] : NULL, BP_DATUM_SIGNED,
                record->value.signed_value);
            break;
        case BP_DATUM_NULL:
            len += encode_context_null(apdu ? &apdu[len] : NULL, BP_DATUM_NULL);
            break;
        default:
            len += encode_opening_tag(apdu ? &apdu[len] : NULL, BP_DATUM_FAILURE);
            len += encode_application_enumerated(
                apdu ? &apdu[len] : NULL, record->value.failure.error_class);
            len += encode_application_enumerated(
                apdu ? &apdu[len] : NULL, record->value.failure.error_code);
            len += encode_closing_tag(apdu ? &apdu[len] : NULL, BP_DATUM_FAILURE);
            break;
    }
    len += encode_closing_tag(apdu ? &apdu[len] : NULL, 1);
    if (record->status_flags != 0xFF) {
        bitstring_init(&bits);
        for (i = 0; i < 4; i++) {
            bitstring_set_bit(
                &bits, (uint8_t)i, (record->status_flags >> i) & 1u);
        }
        len += encode_context_bitstring(apdu ? &apdu[len] : NULL, 2, &bits);
    }
    return len;
}

/* sequence number of record index (1 = oldest) */
static uint32_t bp_tl_sequence(const bp_tl_t *log, uint32_t index)
{
    return log->total - (log->count - index);
}

/* Encodes the records first..last (1 based, inclusive) that fit. */
static int bp_tl_encode_range(
    uint8_t *apdu,
    BACNET_READ_RANGE_DATA *request,
    const bp_tl_t *log,
    uint32_t first,
    uint32_t last,
    bool sequence)
{
    int remaining = MAX_APDU - request->Overhead -
        (sequence ? RR_1ST_SEQ_OVERHEAD : 0);
    uint32_t index;
    int len = 0;
    int record_len;

    request->ItemCount = 0;
    if (first < 1 || first > last || last > log->count) {
        return 0;
    }
    for (index = first; index <= last; index++) {
        record_len = bp_tl_encode_record(NULL, bp_tl_record(log, index));
        if (record_len > remaining) {
            bitstring_set_bit(
                &request->ResultFlags, RESULT_FLAG_MORE_ITEMS, true);
            break;
        }
        len += bp_tl_encode_record(&apdu[len], bp_tl_record(log, index));
        remaining -= record_len;
        request->ItemCount++;
    }
    if (request->ItemCount > 0) {
        bitstring_set_bit(
            &request->ResultFlags, RESULT_FLAG_FIRST_ITEM, first == 1);
        bitstring_set_bit(
            &request->ResultFlags, RESULT_FLAG_LAST_ITEM,
            first + request->ItemCount - 1 == log->count);
        if (sequence) {
            request->FirstSequence = bp_tl_sequence(log, first);
        }
    }
    return len;
}

static int bp_tl_read_range(uint8_t *apdu, BACNET_READ_RANGE_DATA *request)
{
    const bp_tl_t *log = bp_tl(request->object_instance);
    int64_t first;
    int64_t last;
    int64_t offset;
    uint32_t index;

    bitstring_init(&request->ResultFlags);
    bitstring_set_bit(&request->ResultFlags, RESULT_FLAG_FIRST_ITEM, false);
    bitstring_set_bit(&request->ResultFlags, RESULT_FLAG_LAST_ITEM, false);
    bitstring_set_bit(&request->ResultFlags, RESULT_FLAG_MORE_ITEMS, false);
    request->ItemCount = 0;
    if (!log || log->count == 0) {
        return 0;
    }
    switch (request->RequestType) {
        case RR_READ_ALL:
            return bp_tl_encode_range(apdu, request, log, 1, log->count, false);
        case RR_BY_POSITION:
            if (request->Count >= 0) {
                first = request->Range.RefIndex;
                last = first + request->Count - 1;
            } else {
                last = request->Range.RefIndex;
                first = last + request->Count + 1;
            }
            break;
        case RR_BY_SEQUENCE:
            /* position of the reference relative to the oldest record */
            offset = (int32_t)(request->Range.RefSeqNum -
                               bp_tl_sequence(log, 1)) + 1;
            if (request->Count >= 0) {
                first = offset;
                last = first + request->Count - 1;
            } else {
                last = offset;
                first = last + request->Count + 1;
            }
            if (first < 1) {
                first = 1;
            }
            if (last > log->count) {
                last = log->count;
            }
            if (first > last) {
                return 0;
            }
            return bp_tl_encode_range(
                apdu, request, log, (uint32_t)first, (uint32_t)last, true);
        case RR_BY_TIME:
            if (request->Count >= 0) {
                /* records newer than the reference time */
                for (index = 1; index <= log->count; index++) {
                    if (datetime_compare(
                            &bp_tl_record(log, index)->timestamp,
                            &request->Range.RefTime) > 0) {
                        break;
                    }
                }
                first = index;
                last = first + request->Count - 1;
            } else {
                /* records older than the reference time */
                for (index = log->count; index >= 1; index--) {
                    if (datetime_compare(
                            &bp_tl_record(log, index)->timestamp,
                            &request->Range.RefTime) < 0) {
                        break;
                    }
                }
                last = index;
                first = last + request->Count + 1;
            }
            if (first < 1) {
                first = 1;
            }
            if (last > log->count) {
                last = log->count;
            }
            if (first > last || last < 1) {
                return 0;
            }
            return bp_tl_encode_range(
                apdu, request, log, (uint32_t)first, (uint32_t)last, true);
        default:
            return 0;
    }
    /* by position */
    if (first < 1) {
        first = 1;
    }
    if (last > log->count) {
        last = log->count;
    }
    if (first > last) {
        return 0;
    }
    return bp_tl_encode_range(
        apdu, request, log, (uint32_t)first, (uint32_t)last, false);
}

bool bp_tl_rr_info(BACNET_READ_RANGE_DATA *request, RR_PROP_INFO *info)
{
    if (!request || !info) {
        return false;
    }
    if (!bp_tl(request->object_instance)) {
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
    info->Handler = bp_tl_read_range;
    return true;
}

/* ---- API --------------------------------------------------------------- */

BP_API int32_t bacnet_plugin_trend_log_append(
    uint32_t instance,
    const uint8_t *data,
    uint16_t length,
    int32_t status_flags)
{
    bp_tl_record_t record;
    bp_tl_t *log;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if ((length > 0 && !data) || status_flags > 0x0F) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    log = bp_tl(instance);
    if (!log) {
        return BP_ERR_OBJECT;
    }
    if (!bp_tl_effective_enable(log)) {
        return 0;
    }
    memset(&record, 0, sizeof(record));
    Device_getCurrentDateTime(&record.timestamp);
    bp_tl_datum(&record, data, length);
    record.status_flags = status_flags < 0 ? 0xFF : (uint8_t)status_flags;
    bp_tl_insert(log, &record);
    return 1;
}
