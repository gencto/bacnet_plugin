/*
 * bacnet_plugin - Network Port object (ASHRAE 135 clause 12.56). A device at
 * Protocol_Revision >= 17 describes each of its datalinks with a Network Port
 * object. bacnet-stack keeps one unconfigured slot (instance 0 by default);
 * this fills it from the live BACnet/IP (or BACnet/IPv6) socket so the server
 * exposes a proper Network Port instead of the empty placeholder.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdlib.h>
#include <string.h>

#include "bacnet/basic/object/netport.h"
#include "bacnet/datalink/bip.h"
#if !defined(_WIN32) && defined(BACDL_BIP6)
#include "bacnet/datalink/bip6.h"
#endif

#include "bp_internal.h"

/* bacnet-stack keeps BACNET_NETWORK_PORTS_MAX == 1 slot; we own index 0. */
#define BP_NETPORT_INDEX 0

void bp_netport_configure(
    uint32_t instance, uint16_t network_number, const char *name)
{
#if !defined(_WIN32) && defined(BACDL_BIP6)
    const bool ipv6 = bp_state.ipv6;
#else
    const bool ipv6 = false;
#endif
    const char *port_name = ipv6 ? "BACnet/IPv6 Port" : "BACnet/IP Port";

    if (instance == 0 || instance > BACNET_MAX_INSTANCE) {
        instance = 1;
    }
    Network_Port_Object_Instance_Number_Set(BP_NETPORT_INDEX, instance);
    /* netport keeps the name pointer without copying it, so a caller-supplied
       name (unlike a static default) must be parked in the string table */
    if (name && *name) {
        char *previous = NULL;
        char *stored = bp_string_store(
            bp_string_key(OBJECT_NETWORK_PORT, instance, BP_STRING_NAME), name,
            &previous);
        free(previous);
        if (stored) {
            port_name = stored;
        }
    }
    Network_Port_Name_Set(instance, port_name);
#if !defined(_WIN32) && defined(BACDL_BIP6)
    if (ipv6) {
        BACNET_ADDRESS mac = { 0 };
        BACNET_IP6_ADDRESS addr6 = { 0 };

        Network_Port_Type_Set(instance, PORT_TYPE_BIP6);
        Network_Port_BIP6_Port_Set(instance, bip6_get_port());
        bip6_get_my_address(&mac);
        Network_Port_MAC_Address_Set(instance, &mac.mac[0], mac.mac_len);
        if (bip6_get_addr(&addr6)) {
            Network_Port_IPv6_Address_Set(instance, &addr6.address[0]);
        }
        if (bip6_get_broadcast_addr(&addr6)) {
            Network_Port_IPv6_Multicast_Address_Set(
                instance, &addr6.address[0]);
        }
        Network_Port_IPv6_Subnet_Prefix_Set(instance, 0);
    } else
#endif
    {
        BACNET_IP_ADDRESS addr = { 0 };

        Network_Port_Type_Set(instance, PORT_TYPE_BIP);
        if (bip_get_addr(&addr)) {
            Network_Port_BIP_Port_Set(instance, addr.port);
            Network_Port_IP_Address_Set(
                instance, addr.address[0], addr.address[1], addr.address[2],
                addr.address[3]);
        }
        Network_Port_IP_Subnet_Prefix_Set(instance, bip_get_subnet_prefix());
    }
    Network_Port_Link_Speed_Set(instance, 0.0f);
    Network_Port_Reliability_Set(instance, RELIABILITY_NO_FAULT_DETECTED);
    Network_Port_Out_Of_Service_Set(instance, false);
    Network_Port_Quality_Set(instance, PORT_QUALITY_UNKNOWN);
    Network_Port_APDU_Length_Set(instance, MAX_APDU);
    Network_Port_Network_Number_Set(instance, network_number);
    /* the values above mirror the live datalink, so no change is pending */
    Network_Port_Changes_Pending_Set(instance, false);
}

BP_API int32_t bacnet_plugin_network_port_configure(
    uint32_t instance, uint16_t network_number, const char *name)
{
    if (!bp_state.initialized) {
        return BP_ERR_NOT_INITIALIZED;
    }
    bp_netport_configure(instance, network_number, name);
    return BP_OK;
}
