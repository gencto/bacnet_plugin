/*
 * BACnet/IPv6 datalink (ANNEX U) port for POSIX systems.
 *
 * Adapted from bacnet-stack's ports/bsd/bip6.c with the plugin's portability
 * rules: no bacport.h, no s6_addr16 (uses the standard s6_addr bytes), and no
 * exit() on failure (a bad interface or socket makes bip6_init() return
 * false). getifaddrs()/if_nametoindex() work on every supported POSIX target.
 * The BACnet/IPv6 virtual link layer (bvlc6) and VMAC handling are reused
 * unchanged.
 *
 * SPDX-License-Identifier: MIT
 */
#if !defined(_WIN32) && defined(BACDL_BIP6)

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif

#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include "bacnet/bacdcode.h"
#include "bacnet/bacstr.h"
#include "bacnet/datalink/bip6.h"
#include "bacnet/basic/bbmd6/h_bbmd6.h"
#include "bacnet/basic/object/device.h"

/* the open IPv6 UDP socket, -1 when closed */
static int BIP6_Socket = -1;
static int BIP6_Scope_Id = 0;
static BACNET_IP6_ADDRESS BIP6_Addr;
static BACNET_IP6_ADDRESS BIP6_Broadcast_Addr;

/* a 16-bit word of an in6_addr, from its bytes (network order in memory) */
static uint16_t bp_in6_word(const struct in6_addr *addr, int index)
{
    return (uint16_t)((addr->s6_addr[index * 2] << 8) |
                      addr->s6_addr[index * 2 + 1]);
}

/* Fills an in6_addr from eight 16-bit words. */
static void bp_in6_set(struct in6_addr *addr, const uint16_t words[8])
{
    int i;

    for (i = 0; i < 8; i++) {
        addr->s6_addr[i * 2] = (uint8_t)(words[i] >> 8);
        addr->s6_addr[i * 2 + 1] = (uint8_t)(words[i] & 0xFF);
    }
}

int bip6_get_socket(void)
{
    return BIP6_Socket;
}

void bip6_set_interface(const char *ifname)
{
    struct ifaddrs *ifa = NULL;
    struct ifaddrs *entry;

    if (!ifname || getifaddrs(&ifa) == -1) {
        return;
    }
    for (entry = ifa; entry; entry = entry->ifa_next) {
        if (entry->ifa_addr && entry->ifa_addr->sa_family == AF_INET6 &&
            bacnet_stricmp(entry->ifa_name, ifname) == 0) {
            struct sockaddr_in6 *sin =
                (struct sockaddr_in6 *)(void *)entry->ifa_addr;
            bvlc6_address_set(
                &BIP6_Addr, bp_in6_word(&sin->sin6_addr, 0),
                bp_in6_word(&sin->sin6_addr, 1),
                bp_in6_word(&sin->sin6_addr, 2),
                bp_in6_word(&sin->sin6_addr, 3),
                bp_in6_word(&sin->sin6_addr, 4),
                bp_in6_word(&sin->sin6_addr, 5),
                bp_in6_word(&sin->sin6_addr, 6),
                bp_in6_word(&sin->sin6_addr, 7));
            BIP6_Scope_Id = (int)if_nametoindex(ifname);
            break;
        }
    }
    freeifaddrs(ifa);
}

void bip6_set_port(uint16_t port)
{
    BIP6_Addr.port = port;
    BIP6_Broadcast_Addr.port = port;
}

uint16_t bip6_get_port(void)
{
    return BIP6_Addr.port;
}

void bip6_get_broadcast_address(BACNET_ADDRESS *addr)
{
    if (addr) {
        addr->net = BACNET_BROADCAST_NETWORK;
        addr->mac_len = 0;
        addr->len = 0;
    }
}

void bip6_get_my_address(BACNET_ADDRESS *addr)
{
    if (addr) {
        bvlc6_vmac_address_set(addr, Device_Object_Instance_Number());
    }
}

bool bip6_set_addr(const BACNET_IP6_ADDRESS *addr)
{
    return bvlc6_address_copy(&BIP6_Addr, addr);
}

bool bip6_get_addr(BACNET_IP6_ADDRESS *addr)
{
    return bvlc6_address_copy(addr, &BIP6_Addr);
}

bool bip6_set_broadcast_addr(const BACNET_IP6_ADDRESS *addr)
{
    return bvlc6_address_copy(&BIP6_Broadcast_Addr, addr);
}

bool bip6_get_broadcast_addr(BACNET_IP6_ADDRESS *addr)
{
    return bvlc6_address_copy(addr, &BIP6_Broadcast_Addr);
}

int bip6_send_mpdu(
    const BACNET_IP6_ADDRESS *dest, const uint8_t *mtu, uint16_t mtu_len)
{
    struct sockaddr_in6 sin;
    uint16_t words[8];

    if (BIP6_Socket < 0) {
        return 0;
    }
    memset(&sin, 0, sizeof(sin));
    sin.sin6_family = AF_INET6;
    bvlc6_address_get(
        dest, &words[0], &words[1], &words[2], &words[3], &words[4], &words[5],
        &words[6], &words[7]);
    bp_in6_set(&sin.sin6_addr, words);
    sin.sin6_port = htons(dest->port);
    sin.sin6_scope_id = (unsigned)BIP6_Scope_Id;
    return (int)sendto(
        BIP6_Socket, (const char *)mtu, mtu_len, 0, (struct sockaddr *)&sin,
        sizeof(sin));
}

int bip6_send_pdu(
    BACNET_ADDRESS *dest,
    BACNET_NPDU_DATA *npdu_data,
    uint8_t *pdu,
    unsigned pdu_len)
{
    return bvlc6_send_pdu(dest, npdu_data, pdu, pdu_len);
}

uint16_t bip6_receive(
    BACNET_ADDRESS *src, uint8_t *npdu, uint16_t max_npdu, unsigned timeout)
{
    uint16_t npdu_len = 0;
    fd_set read_fds;
    struct timeval select_timeout;
    struct sockaddr_in6 sin;
    socklen_t sin_len = sizeof(sin);
    BACNET_IP6_ADDRESS addr = { 0 };
    int received;
    int offset;
    uint16_t i;

    if (BIP6_Socket < 0) {
        return 0;
    }
    if (timeout >= 1000) {
        select_timeout.tv_sec = timeout / 1000;
        select_timeout.tv_usec =
            1000 * (timeout - select_timeout.tv_sec * 1000);
    } else {
        select_timeout.tv_sec = 0;
        select_timeout.tv_usec = 1000 * timeout;
    }
    FD_ZERO(&read_fds);
    FD_SET(BIP6_Socket, &read_fds);
    if (select(BIP6_Socket + 1, &read_fds, NULL, NULL, &select_timeout) <= 0) {
        return 0;
    }
    memset(&sin, 0, sizeof(sin));
    received = (int)recvfrom(
        BIP6_Socket, (char *)&npdu[0], max_npdu, 0, (struct sockaddr *)&sin,
        &sin_len);
    if (received <= 0) {
        return 0;
    }
    if (npdu[0] != BVLL_TYPE_BACNET_IP6) {
        return 0;
    }
    bvlc6_address_set(
        &addr, bp_in6_word(&sin.sin6_addr, 0), bp_in6_word(&sin.sin6_addr, 1),
        bp_in6_word(&sin.sin6_addr, 2), bp_in6_word(&sin.sin6_addr, 3),
        bp_in6_word(&sin.sin6_addr, 4), bp_in6_word(&sin.sin6_addr, 5),
        bp_in6_word(&sin.sin6_addr, 6), bp_in6_word(&sin.sin6_addr, 7));
    addr.port = ntohs(sin.sin6_port);
    offset = bvlc6_handler(&addr, src, npdu, received);
    if (offset > 0) {
        npdu_len = (uint16_t)(received - offset);
        if (npdu_len <= max_npdu) {
            for (i = 0; i < npdu_len; i++) {
                npdu[i] = npdu[offset + i];
            }
        } else {
            npdu_len = 0;
        }
    }
    return npdu_len;
}

void bip6_cleanup(void)
{
    bvlc6_cleanup();
    if (BIP6_Socket != -1) {
        close(BIP6_Socket);
    }
    BIP6_Socket = -1;
}

void bip6_join_group(void)
{
    struct ipv6_mreq request;

    if (BIP6_Socket < 0) {
        return;
    }
    memset(&request, 0, sizeof(request));
    memcpy(
        &request.ipv6mr_multiaddr, &BIP6_Broadcast_Addr.address[0],
        IP6_ADDRESS_MAX);
    request.ipv6mr_interface = (unsigned)BIP6_Scope_Id;
    /* failure to join (e.g. on loopback) is not fatal */
    (void)setsockopt(
        BIP6_Socket, IPPROTO_IPV6, IPV6_JOIN_GROUP, &request, sizeof(request));
}

void bip6_leave_group(void)
{
    struct ipv6_mreq request;

    if (BIP6_Socket < 0) {
        return;
    }
    memset(&request, 0, sizeof(request));
    memcpy(
        &request.ipv6mr_multiaddr, &BIP6_Broadcast_Addr.address[0],
        IP6_ADDRESS_MAX);
    request.ipv6mr_interface = (unsigned)BIP6_Scope_Id;
    (void)setsockopt(
        BIP6_Socket, IPPROTO_IPV6, IPV6_LEAVE_GROUP, &request, sizeof(request));
}

bool bip6_init(const char *ifname)
{
    struct sockaddr_in6 server;
    int sockopt;

    if (ifname) {
        bip6_set_interface(ifname);
    }
    if (BIP6_Addr.port == 0) {
        bip6_set_port(0xBAC0U);
    }
    if (BIP6_Broadcast_Addr.address[0] == 0) {
        bvlc6_address_set(
            &BIP6_Broadcast_Addr, BIP6_MULTICAST_SITE_LOCAL, 0, 0, 0, 0, 0, 0,
            BIP6_MULTICAST_GROUP_ID);
    }
    BIP6_Socket = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
    if (BIP6_Socket < 0) {
        return false;
    }
    sockopt = 1;
    if (setsockopt(
            BIP6_Socket, SOL_SOCKET, SO_REUSEADDR, &sockopt, sizeof(sockopt)) <
        0) {
        close(BIP6_Socket);
        BIP6_Socket = -1;
        return false;
    }
    bip6_join_group();
    memset(&server, 0, sizeof(server));
    server.sin6_family = AF_INET6;
    server.sin6_addr = in6addr_any;
    server.sin6_port = htons(BIP6_Addr.port);
    if (bind(BIP6_Socket, (const struct sockaddr *)&server, sizeof(server)) <
        0) {
        close(BIP6_Socket);
        BIP6_Socket = -1;
        return false;
    }
    bvlc6_init();
    return true;
}

void bip6_debug_enable(void)
{
}

void bip6_debug_disable(void)
{
}

void bip6_receive_callback(void)
{
}

#endif /* !_WIN32 && BACDL_BIP6 */
