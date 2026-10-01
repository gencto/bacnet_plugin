/*
 * bacnet_plugin - Notification Class objects created by the application.
 *
 * bacnet-stack keeps MAX_NOTIFICATION_CLASSES static Notification Class
 * objects (instances 0 .. MAX_NOTIFICATION_CLASSES - 1) that always exist.
 * The plugin server exposes only the instances the application created,
 * so the object table uses these wrappers: an instance exists between
 * CreateObject and DeleteObject and starts with the defaults of
 * Notification_Class_Init() (no recipients, priorities 255, no
 * acknowledgements required).
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>
#include <string.h>

#include "bacnet/bacdcode.h"
#include "bacnet/bacstr.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/object/nc.h"

#include "bp_internal.h"

#if defined(INTRINSIC_REPORTING)

#ifndef MAX_NOTIFICATION_CLASSES
#define MAX_NOTIFICATION_CLASSES 2
#endif

static bool bp_nc_used[MAX_NOTIFICATION_CLASSES];
static const char *bp_nc_names[MAX_NOTIFICATION_CLASSES];
static const char *bp_nc_descriptions[MAX_NOTIFICATION_CLASSES];

static void bp_nc_reset(uint32_t instance)
{
    uint32_t priorities[MAX_BACNET_EVENT_TRANSITION] = { 255, 255, 255 };
    BACNET_DESTINATION recipients[NC_MAX_RECIPIENTS];
    unsigned i;

    for (i = 0; i < NC_MAX_RECIPIENTS; i++) {
        bacnet_destination_default_init(&recipients[i]);
    }
    Notification_Class_Set_Priorities(instance, priorities);
    Notification_Class_Set_Ack_Required(instance, 0);
    (void)Notification_Class_Set_Recipient_List(instance, recipients);
    bp_nc_names[instance] = NULL;
    bp_nc_descriptions[instance] = NULL;
}

void bp_nc_init(void)
{
    Notification_Class_Init();
    memset(bp_nc_used, 0, sizeof(bp_nc_used));
    memset((void *)bp_nc_names, 0, sizeof(bp_nc_names));
    memset((void *)bp_nc_descriptions, 0, sizeof(bp_nc_descriptions));
}

bool bp_nc_valid_instance(uint32_t instance)
{
    return instance < MAX_NOTIFICATION_CLASSES && bp_nc_used[instance];
}

unsigned bp_nc_count(void)
{
    unsigned count = 0;
    unsigned i;

    for (i = 0; i < MAX_NOTIFICATION_CLASSES; i++) {
        if (bp_nc_used[i]) {
            count++;
        }
    }
    return count;
}

uint32_t bp_nc_index_to_instance(unsigned index)
{
    unsigned i;

    for (i = 0; i < MAX_NOTIFICATION_CLASSES; i++) {
        if (bp_nc_used[i]) {
            if (index == 0) {
                return i;
            }
            index--;
        }
    }
    return BACNET_MAX_INSTANCE;
}

bool bp_nc_object_name(uint32_t instance, BACNET_CHARACTER_STRING *name)
{
    char text[32];

    if (!bp_nc_valid_instance(instance)) {
        return false;
    }
    if (bp_nc_names[instance]) {
        return characterstring_init_ansi(name, bp_nc_names[instance]);
    }
    snprintf(
        text, sizeof(text), "Notification Class %lu", (unsigned long)instance);
    return characterstring_init_ansi(name, text);
}

bool bp_nc_name_set(uint32_t instance, const char *name)
{
    if (!bp_nc_valid_instance(instance)) {
        return false;
    }
    bp_nc_names[instance] = name;
    return true;
}

bool bp_nc_description_set(uint32_t instance, const char *description)
{
    if (!bp_nc_valid_instance(instance)) {
        return false;
    }
    bp_nc_descriptions[instance] = description;
    return true;
}

int bp_nc_read_property(BACNET_READ_PROPERTY_DATA *rpdata)
{
    BACNET_CHARACTER_STRING text;
    const char *description;

    if (!rpdata || !rpdata->application_data ||
        rpdata->application_data_len <= 0 ||
        rpdata->array_index != BACNET_ARRAY_ALL) {
        return Notification_Class_Read_Property(rpdata);
    }
    /* bacnet-stack names the objects itself */
    switch (rpdata->object_property) {
        case PROP_OBJECT_NAME:
            if (!bp_nc_object_name(rpdata->object_instance, &text)) {
                break;
            }
            return encode_application_character_string(
                rpdata->application_data, &text);
        case PROP_DESCRIPTION:
            if (!bp_nc_valid_instance(rpdata->object_instance)) {
                break;
            }
            description = bp_nc_descriptions[rpdata->object_instance];
            characterstring_init_ansi(&text, description ? description : "");
            return encode_application_character_string(
                rpdata->application_data, &text);
        default:
            break;
    }
    return Notification_Class_Read_Property(rpdata);
}

uint32_t bp_nc_create(uint32_t instance)
{
    unsigned i;

    if (instance == BACNET_MAX_INSTANCE) {
        /* CreateObject without an instance: the first free one */
        for (i = 0; i < MAX_NOTIFICATION_CLASSES; i++) {
            if (!bp_nc_used[i]) {
                instance = i;
                break;
            }
        }
    }
    if (instance >= MAX_NOTIFICATION_CLASSES) {
        return BACNET_MAX_INSTANCE;
    }
    if (!bp_nc_used[instance]) {
        bp_nc_reset(instance);
        bp_nc_used[instance] = true;
    }
    return instance;
}

bool bp_nc_delete(uint32_t instance)
{
    if (!bp_nc_valid_instance(instance)) {
        return false;
    }
    bp_nc_used[instance] = false;
    bp_nc_reset(instance);
    return true;
}

#endif
