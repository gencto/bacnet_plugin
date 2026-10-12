/*
 * Server as a BACnet router (ASHRAE 135 clause 6). The engine hosts a single
 * device, but it can advertise itself as the router to a set of virtual
 * networks: it answers Who-Is-Router-To-Network with I-Am-Router-To-Network
 * and Initialize-Routing-Table with an acknowledgement listing those networks
 * (BIBB NM-RC-B). Forwarding of APDUs to devices behind the router is a larger
 * feature and is not implemented.
 *
 * SPDX-License-Identifier: MIT
 */
#include <string.h>

#include "bacnet_plugin.h"
#include "bacnet/npdu.h"
#include "bacnet/basic/npdu/s_router.h"
#include "bp_internal.h"

#ifndef BP_ROUTER_MAX
#define BP_ROUTER_MAX 16u
#endif

/* the advertised networks, terminated by -1 as Send_Network_Layer_Message
   expects */
static int32_t bp_router_list[BP_ROUTER_MAX + 1] = { -1 };
static uint32_t bp_router_num;

BP_API int32_t
bacnet_plugin_router_configure(const int32_t *networks, uint32_t count)
{
    uint32_t i;

    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    if (count > BP_ROUTER_MAX || (count > 0 && !networks)) {
        return BP_ERR_INVALID_ARGUMENT;
    }
    for (i = 0; i < count; i++) {
        if (networks[i] < 1 || networks[i] > 0xFFFF) {
            return BP_ERR_INVALID_ARGUMENT;
        }
        bp_router_list[i] = networks[i];
    }
    bp_router_list[count] = -1;
    bp_router_num = count;
    return BP_OK;
}

static bool bp_router_knows(int32_t dnet)
{
    uint32_t i;

    for (i = 0; i < bp_router_num; i++) {
        if (bp_router_list[i] == dnet) {
            return true;
        }
    }
    return false;
}

void bp_router_on_network_message(
    BACNET_ADDRESS *src,
    const BACNET_NPDU_DATA *npdu_data,
    const uint8_t *message,
    uint16_t message_len)
{
    if (bp_router_num == 0 || !bp_state.server_enabled || !npdu_data) {
        return;
    }
    switch (npdu_data->network_message_type) {
        case NETWORK_MESSAGE_WHO_IS_ROUTER_TO_NETWORK:
            if (message_len >= 2) {
                int32_t dnet = (int32_t)((message[0] << 8) | message[1]);
                if (bp_router_knows(dnet)) {
                    int32_t one[2] = { dnet, -1 };
                    (void)Send_Network_Layer_Message(
                        NETWORK_MESSAGE_I_AM_ROUTER_TO_NETWORK, src, one);
                }
            } else {
                /* no DNET: advertise every network we route to */
                (void)Send_Network_Layer_Message(
                    NETWORK_MESSAGE_I_AM_ROUTER_TO_NETWORK, src,
                    bp_router_list);
            }
            break;
        case NETWORK_MESSAGE_INIT_RT_TABLE:
            (void)Send_Network_Layer_Message(
                NETWORK_MESSAGE_INIT_RT_TABLE_ACK, src, bp_router_list);
            break;
        default:
            break;
    }
}
