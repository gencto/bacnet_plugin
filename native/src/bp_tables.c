/*
 * bacnet_plugin - device address table and string storage.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdlib.h>
#include <string.h>

#include "bp_internal.h"

/* ---- device table (open addressing hash map) -------------------------- */

static uint32_t bp_hash32(uint32_t x)
{
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

bp_device_entry_t *bp_device_find(uint32_t device_id)
{
    uint32_t mask;
    uint32_t i;

    if (!bp_state.devices.entries) {
        return NULL;
    }
    mask = bp_state.devices.capacity - 1;
    for (i = bp_hash32(device_id) & mask;; i = (i + 1) & mask) {
        bp_device_entry_t *e = &bp_state.devices.entries[i];
        if (e->state == 0) {
            return NULL;
        }
        if (e->state == 1 && e->device_id == device_id) {
            return e;
        }
    }
}

static bool bp_device_rehash(uint32_t capacity)
{
    bp_device_entry_t *old = bp_state.devices.entries;
    uint32_t old_capacity = bp_state.devices.capacity;
    uint32_t i;

    bp_state.devices.entries =
        (bp_device_entry_t *)calloc(capacity, sizeof(bp_device_entry_t));
    if (!bp_state.devices.entries) {
        bp_state.devices.entries = old;
        return false;
    }
    bp_state.devices.capacity = capacity;
    bp_state.devices.used = 0;
    bp_state.devices.deleted = 0;
    for (i = 0; i < old_capacity; i++) {
        if (old[i].state == 1) {
            uint32_t mask = capacity - 1;
            uint32_t j = bp_hash32(old[i].device_id) & mask;
            while (bp_state.devices.entries[j].state != 0) {
                j = (j + 1) & mask;
            }
            bp_state.devices.entries[j] = old[i];
            bp_state.devices.used++;
        }
    }
    free(old);
    return true;
}

bp_device_entry_t *bp_device_put(
    uint32_t device_id, const BACNET_ADDRESS *address, uint16_t max_apdu)
{
    bp_device_entry_t *e = bp_device_find(device_id);
    uint32_t mask;
    uint32_t i;

    if (!e) {
        if (!bp_state.devices.entries ||
            (bp_state.devices.used + bp_state.devices.deleted + 1) * 4 >
                bp_state.devices.capacity * 3) {
            uint32_t capacity =
                bp_state.devices.capacity ? bp_state.devices.capacity : 256;
            if ((bp_state.devices.used + 1) * 2 > capacity) {
                capacity *= 2;
            }
            if (!bp_device_rehash(capacity)) {
                return NULL;
            }
        }
        mask = bp_state.devices.capacity - 1;
        for (i = bp_hash32(device_id) & mask;; i = (i + 1) & mask) {
            e = &bp_state.devices.entries[i];
            if (e->state != 1) {
                if (e->state == 2) {
                    bp_state.devices.deleted--;
                }
                break;
            }
        }
        memset(e, 0, sizeof(*e));
        e->state = 1;
        e->device_id = device_id;
        bp_state.devices.used++;
    }
    bacnet_address_copy(&e->address, address);
    e->max_apdu = max_apdu ? max_apdu : MAX_APDU;
    return e;
}

void bp_device_remove(uint32_t device_id)
{
    bp_device_entry_t *e = bp_device_find(device_id);

    if (e) {
        e->state = 2;
        bp_state.devices.used--;
        bp_state.devices.deleted++;
    }
}

/* ---- string table ------------------------------------------------------ */

uint64_t bp_string_key(uint16_t type, uint32_t instance, uint8_t slot)
{
    return ((uint64_t)slot << 48) | ((uint64_t)type << 32) | instance;
}

static uint32_t bp_hash64(uint64_t key)
{
    return bp_hash32((uint32_t)key ^ bp_hash32((uint32_t)(key >> 32)));
}

bp_string_entry_t *bp_string_slot(uint64_t key, bool insert)
{
    uint32_t mask;
    uint32_t i;
    bp_string_entry_t *tombstone = NULL;

    if (insert &&
        (!bp_state.strings.entries ||
         (bp_state.strings.used + bp_state.strings.deleted + 1) * 4 >
             bp_state.strings.capacity * 3)) {
        bp_string_entry_t *old = bp_state.strings.entries;
        uint32_t old_capacity = bp_state.strings.capacity;
        uint32_t capacity = old_capacity ? old_capacity : 64;
        if ((bp_state.strings.used + 1) * 2 > capacity) {
            capacity *= 2;
        }
        bp_state.strings.entries =
            (bp_string_entry_t *)calloc(capacity, sizeof(bp_string_entry_t));
        if (!bp_state.strings.entries) {
            bp_state.strings.entries = old;
            return NULL;
        }
        bp_state.strings.capacity = capacity;
        bp_state.strings.used = 0;
        bp_state.strings.deleted = 0;
        for (i = 0; i < old_capacity; i++) {
            if (old[i].state == 1) {
                uint32_t j = bp_hash64(old[i].key) & (capacity - 1);
                while (bp_state.strings.entries[j].state != 0) {
                    j = (j + 1) & (capacity - 1);
                }
                bp_state.strings.entries[j] = old[i];
                bp_state.strings.used++;
            }
        }
        free(old);
    }
    if (!bp_state.strings.entries) {
        return NULL;
    }
    mask = bp_state.strings.capacity - 1;
    for (i = bp_hash64(key) & mask;; i = (i + 1) & mask) {
        bp_string_entry_t *e = &bp_state.strings.entries[i];
        if (e->state == 0) {
            if (!insert) {
                return NULL;
            }
            if (tombstone) {
                bp_state.strings.deleted--;
                e = tombstone;
            }
            e->state = 1;
            e->key = key;
            e->value = NULL;
            bp_state.strings.used++;
            return e;
        }
        if (e->state == 2) {
            if (!tombstone) {
                tombstone = e;
            }
        } else if (e->key == key) {
            return e;
        }
    }
}

/** Stores a copy of value and returns the stable pointer (old one freed
 *  by the caller via the returned previous pointer). */
char *bp_string_store(uint64_t key, const char *value, char **previous)
{
    bp_string_entry_t *e = bp_string_slot(key, true);
    size_t len;
    char *copy;

    *previous = NULL;
    if (!e) {
        return NULL;
    }
    len = strlen(value);
    copy = (char *)malloc(len + 1);
    if (!copy) {
        return NULL;
    }
    memcpy(copy, value, len + 1);
    *previous = e->value;
    e->value = copy;
    return copy;
}

/** Like bp_string_store() for a buffer that may contain NUL bytes. */
char *
bp_bytes_store(uint64_t key, const char *value, uint32_t len, char **previous)
{
    bp_string_entry_t *e = bp_string_slot(key, true);
    char *copy;

    *previous = NULL;
    if (!e) {
        return NULL;
    }
    copy = (char *)malloc(len + 2);
    if (!copy) {
        return NULL;
    }
    memcpy(copy, value, len);
    copy[len] = 0;
    copy[len + 1] = 0;
    *previous = e->value;
    e->value = copy;
    return copy;
}

void bp_string_remove(uint64_t key)
{
    bp_string_entry_t *e = bp_string_slot(key, false);

    if (e) {
        free(e->value);
        e->value = NULL;
        e->state = 2;
        bp_state.strings.used--;
        bp_state.strings.deleted++;
    }
}

void bp_string_clear(void)
{
    uint32_t i;

    for (i = 0; i < bp_state.strings.capacity; i++) {
        if (bp_state.strings.entries[i].state == 1) {
            free(bp_state.strings.entries[i].value);
        }
    }
    free(bp_state.strings.entries);
    memset(&bp_state.strings, 0, sizeof(bp_state.strings));
}
