/*
 * Time Master (ASHRAE 135 clause 13.12, BIBB DM-TS-A / DM-UTC-A): the server
 * periodically broadcasts or unicasts TimeSynchronization (local time) or
 * UTCTimeSynchronization to a list of recipients, optionally aligned to the
 * wall clock. bacnet-stack's handler_timesync_task only sends local time to
 * address recipients and depends on BACNET_TIME_MASTER, so the engine keeps
 * its own small scheduler on top of the Send_TimeSync* primitives.
 */
#include <string.h>

#include "bacnet_plugin.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/services.h"
#include "bacnet/datetime.h"
#include "bp_internal.h"

#define BP_TIME_MASTER_MAX_RECIPIENTS 16u

typedef struct {
    uint32_t device_id; /* resolved through the binding table; 0 for address */
    BACNET_ADDRESS address; /* used when device_id == 0; mac_len 0 = broadcast */
} bp_time_recipient_t;

static struct {
    bool enabled;
    bool utc;
    bool align;
    uint32_t interval_ms;
    uint32_t offset_ms;
    uint32_t next_ms;
    bool scheduled;
    uint16_t count;
    bp_time_recipient_t list[BP_TIME_MASTER_MAX_RECIPIENTS];
} bp_tm;

/* Milliseconds since local midnight, from the device's clock. */
static uint32_t bp_time_ms_of_day(void)
{
    BACNET_DATE_TIME now;

    Device_getCurrentDateTime(&now);
    return (((uint32_t)now.time.hour * 60u + now.time.min) * 60u +
            now.time.sec) *
        1000u +
        (uint32_t)now.time.hundredths * 10u;
}

/* Picks the next send time from now, aligning to the wall clock if asked. */
static void bp_time_master_schedule(uint32_t now_ms)
{
    uint32_t period = bp_tm.interval_ms;

    if (bp_tm.align && period > 0) {
        uint32_t offset = bp_tm.offset_ms % period;
        uint32_t day_ms = bp_time_ms_of_day();
        uint32_t steps = day_ms >= offset ? (day_ms - offset) / period + 1 : 0;
        uint32_t next_ms = offset + steps * period;
        uint32_t delta = next_ms - day_ms;

        if (delta == 0) {
            delta = period;
        }
        bp_tm.next_ms = now_ms + delta;
    } else {
        bp_tm.next_ms = now_ms + period;
    }
    bp_tm.scheduled = true;
}

/* Sends the current time to one recipient. */
static void bp_time_master_send_one(
    const bp_time_recipient_t *recipient,
    const BACNET_DATE *date,
    const BACNET_TIME *time)
{
    BACNET_ADDRESS dest;

    if (recipient->device_id) {
        bp_device_entry_t *device = bp_device_find(recipient->device_id);
        if (!device || device->address.mac_len == 0) {
            /* not bound yet: a later tick sends once the address is known */
            return;
        }
        dest = device->address;
    } else if (recipient->address.mac_len == 0) {
        /* a broadcast on the local network */
        if (bp_tm.utc) {
            Send_TimeSyncUTC(date, time);
        } else {
            Send_TimeSync(date, time);
        }
        return;
    } else {
        dest = recipient->address;
    }
    if (bp_tm.utc) {
        Send_TimeSyncUTC_Remote(&dest, date, time);
    } else {
        Send_TimeSync_Remote(&dest, date, time);
    }
}

/* Sends the current time to every recipient. */
static void bp_time_master_fire(void)
{
    BACNET_DATE_TIME local;
    BACNET_DATE_TIME utc;
    const BACNET_DATE *date;
    const BACNET_TIME *time;
    uint16_t i;

    Device_getCurrentDateTime(&local);
    if (bp_tm.utc) {
        datetime_copy(&utc, &local);
        datetime_add_minutes(&utc, Device_UTC_Offset());
        if (Device_Daylight_Savings_Status()) {
            datetime_add_minutes(&utc, -60);
        }
        date = &utc.date;
        time = &utc.time;
    } else {
        date = &local.date;
        time = &local.time;
    }
    for (i = 0; i < bp_tm.count; i++) {
        bp_time_master_send_one(&bp_tm.list[i], date, time);
    }
}

void bp_time_master_tick(uint32_t now_ms)
{
    if (!bp_tm.enabled || bp_tm.interval_ms == 0 || !bp_state.server_enabled) {
        return;
    }
    if (!bp_tm.scheduled) {
        bp_time_master_schedule(now_ms);
        return;
    }
    if ((int32_t)(now_ms - bp_tm.next_ms) < 0) {
        return;
    }
    bp_time_master_fire();
    bp_time_master_schedule(now_ms);
}

BP_API int32_t bacnet_plugin_time_master_configure(
    int32_t enabled,
    uint32_t interval_seconds,
    int32_t utc,
    int32_t align,
    uint32_t offset_seconds)
{
    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (enabled && interval_seconds == 0) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    if (interval_seconds > 0xFFFFFFFFu / 1000u ||
        offset_seconds > 0xFFFFFFFFu / 1000u) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    bp_tm.enabled = enabled != 0;
    bp_tm.utc = utc != 0;
    bp_tm.align = align != 0;
    bp_tm.interval_ms = interval_seconds * 1000u;
    bp_tm.offset_ms = offset_seconds * 1000u;
    bp_tm.scheduled = false;
    return BP_OK;
}

BP_API int32_t bacnet_plugin_time_master_clear_recipients(void)
{
    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    bp_tm.count = 0;
    return BP_OK;
}

BP_API int32_t bacnet_plugin_time_master_add_recipient(
    uint32_t device_id,
    const uint8_t *mac,
    uint8_t mac_len,
    uint16_t net,
    const uint8_t *adr,
    uint8_t adr_len)
{
    bp_time_recipient_t *recipient;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if ((mac_len > 0 && !mac) || (adr_len > 0 && !adr) ||
        mac_len > MAX_MAC_LEN || adr_len > MAX_MAC_LEN ||
        (adr_len > 0 && net == 0)) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    if (bp_tm.count >= BP_TIME_MASTER_MAX_RECIPIENTS) {
        return BP_ERR_NO_MEMORY;
    }
    recipient = &bp_tm.list[bp_tm.count];
    memset(recipient, 0, sizeof(*recipient));
    recipient->device_id = device_id;
    if (!device_id) {
        recipient->address.mac_len = mac_len;
        if (mac_len) {
            memcpy(recipient->address.mac, mac, mac_len);
        }
        recipient->address.net = net;
        recipient->address.len = adr_len;
        if (adr_len) {
            memcpy(recipient->address.adr, adr, adr_len);
        }
    }
    bp_tm.count++;
    return BP_OK;
}
