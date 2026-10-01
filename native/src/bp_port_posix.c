/*
 * BACnet/IPv4 datalink, timer and clock port for POSIX systems
 * (Linux, Android, macOS, iOS).
 *
 * Replaces ports/linux and ports/bsd of bacnet-stack, which depend on
 * /proc, netlink, root-only socket options and headers that are not part of
 * the iOS SDK. Interface discovery uses getifaddrs(), which is available on
 * every supported POSIX target.
 *
 * SPDX-License-Identifier: MIT
 */
#if !defined(_WIN32)

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "bacnet/bacdef.h"
#include "bacnet/datalink/bip.h"
#include "bacnet/datalink/bvlc.h"
#include "bacnet/basic/bbmd/h_bbmd.h"
#include "bacnet/basic/sys/mstimer.h"
#include "bacnet/datetime.h"

#include "bp_port.h"

/* sockets */
static int BIP_Socket = -1;
static int BIP_Broadcast_Socket = -1;
/* addresses and port in network byte order */
static uint16_t BIP_Port;
static uint16_t BIP_Broadcast_Port;
static struct in_addr BIP_Address;
static struct in_addr BIP_Broadcast_Addr;
static struct in_addr BIP_Netmask;
static bool BIP_Broadcast_Binding_Address_Override;
static struct in_addr BIP_Broadcast_Binding_Address;
static char BIP_Interface_Name[IF_NAMESIZE + 1];
static int BIP_Socket_Buffer_Size;

void bp_port_set_socket_buffer_size(int bytes)
{
    BIP_Socket_Buffer_Size = bytes;
}

void bip_debug_enable(void)
{
}

void bip_debug_disable(void)
{
}

int bip_get_socket(void)
{
    return BIP_Socket;
}

int bip_get_broadcast_socket(void)
{
    return BIP_Broadcast_Socket;
}

void bip_set_port(uint16_t port)
{
    BIP_Port = htons(port);
}

bool bip_port_changed(void)
{
    return false;
}

void bip_set_broadcast_port(uint16_t port)
{
    BIP_Broadcast_Port = htons(port);
}

uint16_t bip_get_port(void)
{
    return ntohs(BIP_Port);
}

uint16_t bip_get_broadcast_port(void)
{
    if (BIP_Broadcast_Port) {
        return ntohs(BIP_Broadcast_Port);
    }
    return ntohs(BIP_Port);
}

void bip_get_my_address(BACNET_ADDRESS *addr)
{
    if (addr) {
        memset(addr, 0, sizeof(*addr));
        addr->mac_len = 6;
        memcpy(&addr->mac[0], &BIP_Address.s_addr, 4);
        memcpy(&addr->mac[4], &BIP_Port, 2);
    }
}

void bip_get_broadcast_address(BACNET_ADDRESS *dest)
{
    uint16_t port = htons(bip_get_broadcast_port());

    if (dest) {
        memset(dest, 0, sizeof(*dest));
        dest->mac_len = 6;
        memcpy(&dest->mac[0], &BIP_Broadcast_Addr.s_addr, 4);
        memcpy(&dest->mac[4], &port, 2);
        dest->net = BACNET_BROADCAST_NETWORK;
    }
}

bool bip_set_addr(const BACNET_IP_ADDRESS *addr)
{
    (void)addr;
    return false;
}

bool bip_get_addr(BACNET_IP_ADDRESS *addr)
{
    if (addr) {
        memcpy(&addr->address[0], &BIP_Address.s_addr, 4);
        addr->port = ntohs(BIP_Port);
    }
    return true;
}

bool bip_set_broadcast_addr(const BACNET_IP_ADDRESS *addr)
{
    if (!addr) {
        return false;
    }
    memcpy(&BIP_Broadcast_Addr.s_addr, &addr->address[0], 4);
    return true;
}

bool bip_get_broadcast_addr(BACNET_IP_ADDRESS *addr)
{
    if (addr) {
        memcpy(&addr->address[0], &BIP_Broadcast_Addr.s_addr, 4);
        addr->port = bip_get_broadcast_port();
    }
    return true;
}

bool bip_get_gateway_addr(BACNET_IP_ADDRESS *addr)
{
    if (addr) {
        memset(addr, 0, sizeof(*addr));
    }
    return false;
}

bool bip_set_subnet_prefix(uint8_t prefix)
{
    uint32_t mask;

    if ((prefix == 0) || (prefix > 32)) {
        return false;
    }
    mask = (prefix == 32) ? UINT32_MAX : (UINT32_MAX << (32 - prefix));
    BIP_Netmask.s_addr = htonl(mask);
    if ((BIP_Address.s_addr != 0) && !BIP_Broadcast_Binding_Address_Override) {
        uint32_t address = ntohl(BIP_Address.s_addr);
        BIP_Broadcast_Addr.s_addr = htonl((address & mask) | (~mask));
    }
    return true;
}

uint8_t bip_get_subnet_prefix(void)
{
    uint32_t mask = ntohl(BIP_Netmask.s_addr);
    uint8_t prefix = 0;

    while ((mask & 0x80000000u) != 0) {
        prefix++;
        mask <<= 1;
    }
    return (mask != 0) ? 0 : prefix;
}

int bip_set_broadcast_binding(const char *ip4_broadcast)
{
    if (!ip4_broadcast ||
        inet_pton(AF_INET, ip4_broadcast, &BIP_Broadcast_Binding_Address) !=
            1) {
        return -1;
    }
    BIP_Broadcast_Binding_Address_Override = true;
    return 0;
}

bool bip_get_addr_by_name(const char *host_name, BACNET_IP_ADDRESS *addr)
{
    struct addrinfo hints;
    struct addrinfo *result = NULL;
    bool status = false;

    if (!host_name || !addr) {
        return false;
    }
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(host_name, NULL, &hints, &result) == 0 && result) {
        const struct sockaddr_in *sin =
            (const struct sockaddr_in *)result->ai_addr;
        memcpy(&addr->address[0], &sin->sin_addr.s_addr, 4);
        status = true;
    }
    if (result) {
        freeaddrinfo(result);
    }
    return status;
}

int bip_send_mpdu(
    const BACNET_IP_ADDRESS *dest, const uint8_t *mtu, uint16_t mtu_len)
{
    struct sockaddr_in bip_dest;
    ssize_t sent;

    if (BIP_Socket < 0 || !dest) {
        return -1;
    }
    memset(&bip_dest, 0, sizeof(bip_dest));
    bip_dest.sin_family = AF_INET;
    memcpy(&bip_dest.sin_addr.s_addr, &dest->address[0], 4);
    bip_dest.sin_port = htons(dest->port);
    do {
        sent = sendto(
            BIP_Socket, (const char *)mtu, mtu_len, 0,
            (struct sockaddr *)&bip_dest, sizeof(bip_dest));
    } while (sent < 0 && errno == EINTR);
    return (int)sent;
}

int bip_send_pdu(
    BACNET_ADDRESS *dest,
    BACNET_NPDU_DATA *npdu_data,
    uint8_t *pdu,
    unsigned pdu_len)
{
    return bvlc_send_pdu(dest, npdu_data, pdu, pdu_len);
}

static int bip_recv_from(
    int sock, uint8_t *buf, uint16_t max, struct sockaddr_in *sin)
{
    socklen_t sin_len = sizeof(*sin);
    ssize_t n;

    do {
        n = recvfrom(
            sock, (char *)buf, max, MSG_DONTWAIT, (struct sockaddr *)sin,
            &sin_len);
    } while (n < 0 && errno == EINTR);
    return (int)n;
}

uint16_t bip_receive(
    BACNET_ADDRESS *src, uint8_t *npdu, uint16_t max_npdu, unsigned timeout)
{
    struct sockaddr_in sin;
    BACNET_IP_ADDRESS addr;
    int received = -1;
    int sock = BIP_Socket;
    int offset = 0;
    uint16_t npdu_len = 0;

    if (BIP_Socket < 0) {
        return 0;
    }
    if (timeout > 0) {
        struct pollfd fds[2];
        nfds_t nfds = 1;

        fds[0].fd = BIP_Socket;
        fds[0].events = POLLIN;
        fds[0].revents = 0;
        if (BIP_Broadcast_Socket >= 0 && BIP_Broadcast_Socket != BIP_Socket) {
            fds[1].fd = BIP_Broadcast_Socket;
            fds[1].events = POLLIN;
            fds[1].revents = 0;
            nfds = 2;
        }
        if (poll(fds, nfds, (int)timeout) <= 0) {
            return 0;
        }
    }
    memset(&sin, 0, sizeof(sin));
    received = bip_recv_from(BIP_Socket, npdu, max_npdu, &sin);
    if (received < 0 && BIP_Broadcast_Socket >= 0 &&
        BIP_Broadcast_Socket != BIP_Socket) {
        sock = BIP_Broadcast_Socket;
        received = bip_recv_from(BIP_Broadcast_Socket, npdu, max_npdu, &sin);
    }
    if (received <= 0) {
        return 0;
    }
    if (npdu[0] != BVLL_TYPE_BACNET_IP) {
        return 0;
    }
    /* ignore our own broadcasts */
    if ((sin.sin_addr.s_addr == BIP_Address.s_addr) &&
        (sin.sin_port == BIP_Port)) {
        return 0;
    }
    /* zero a safety margin after the received data for the decoders */
    if (received < max_npdu) {
        int margin = max_npdu - received;
        memset(&npdu[received], 0, margin > 16 ? 16 : margin);
    }
    memcpy(&addr.address[0], &sin.sin_addr.s_addr, 4);
    addr.port = ntohs(sin.sin_port);
    if (sock == BIP_Socket) {
        offset = bvlc_handler(&addr, src, npdu, (uint16_t)received);
    } else {
        offset = bvlc_broadcast_handler(&addr, src, npdu, (uint16_t)received);
    }
    if (offset > 0 && offset < received) {
        npdu_len = (uint16_t)(received - offset);
        memmove(&npdu[0], &npdu[offset], npdu_len);
    }
    return npdu_len;
}

/**
 * Selects the interface: by name, by IPv4 address, or the first non-loopback
 * IPv4 interface that is up (falling back to loopback).
 */
static bool bip_select_interface(const char *ifname)
{
    struct ifaddrs *list = NULL;
    struct ifaddrs *ifa;
    struct ifaddrs *best = NULL;
    struct in_addr wanted;
    bool by_address = false;

    if (ifname && *ifname) {
        by_address = (inet_pton(AF_INET, ifname, &wanted) == 1);
    }
    if (getifaddrs(&list) != 0) {
        return false;
    }
    for (ifa = list; ifa; ifa = ifa->ifa_next) {
        const struct sockaddr_in *sin;

        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        if ((ifa->ifa_flags & IFF_UP) == 0) {
            continue;
        }
        sin = (const struct sockaddr_in *)ifa->ifa_addr;
        if (ifname && *ifname) {
            if (by_address) {
                if (sin->sin_addr.s_addr == wanted.s_addr) {
                    best = ifa;
                    break;
                }
            } else if (strcmp(ifa->ifa_name, ifname) == 0) {
                best = ifa;
                break;
            }
            continue;
        }
        if ((ifa->ifa_flags & IFF_LOOPBACK) == 0) {
            if (!best || (best->ifa_flags & IFF_LOOPBACK) != 0) {
                best = ifa;
            }
        } else if (!best) {
            best = ifa;
        }
    }
    if (best) {
        const struct sockaddr_in *sin =
            (const struct sockaddr_in *)best->ifa_addr;
        uint32_t address;
        uint32_t mask;

        BIP_Address = sin->sin_addr;
        if (best->ifa_netmask) {
            BIP_Netmask =
                ((const struct sockaddr_in *)best->ifa_netmask)->sin_addr;
        } else {
            BIP_Netmask.s_addr = htonl(0xFFFFFF00u);
        }
        address = ntohl(BIP_Address.s_addr);
        mask = ntohl(BIP_Netmask.s_addr);
        if ((best->ifa_flags & IFF_BROADCAST) && best->ifa_broadaddr &&
            best->ifa_broadaddr->sa_family == AF_INET) {
            BIP_Broadcast_Addr =
                ((const struct sockaddr_in *)best->ifa_broadaddr)->sin_addr;
        } else {
            BIP_Broadcast_Addr.s_addr = htonl((address & mask) | (~mask));
        }
        snprintf(
            BIP_Interface_Name, sizeof(BIP_Interface_Name), "%s",
            best->ifa_name);
    }
    freeifaddrs(list);
    return best != NULL;
}

void bip_set_interface(const char *ifname)
{
    (void)bip_select_interface(ifname);
}

const char *bip_get_interface(void)
{
    return BIP_Interface_Name;
}

static void bip_apply_buffer_size(int sock)
{
    if (BIP_Socket_Buffer_Size > 0) {
        int size = BIP_Socket_Buffer_Size;
        (void)setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
        size = BIP_Socket_Buffer_Size;
        (void)setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
    }
}

static int bip_create_socket(const struct sockaddr_in *sin)
{
    int value = 1;
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);

    if (sock < 0) {
        return -1;
    }
    (void)fcntl(sock, F_SETFD, FD_CLOEXEC);
    if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &value, sizeof(value)) <
            0 ||
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &value, sizeof(value)) <
            0) {
        close(sock);
        return -1;
    }
#if defined(SO_NOSIGPIPE)
    (void)setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &value, sizeof(value));
#endif
    bip_apply_buffer_size(sock);
    if (bind(sock, (const struct sockaddr *)sin, sizeof(*sin)) < 0) {
        close(sock);
        return -1;
    }
    return sock;
}

bool bip_init(const char *ifname)
{
    struct sockaddr_in sin;

    if (BIP_Port == 0) {
        BIP_Port = htons(0xBAC0);
    }
    if (!bip_select_interface(ifname) || BIP_Address.s_addr == 0) {
        return false;
    }
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = BIP_Port;
    sin.sin_addr = BIP_Address;
    BIP_Socket = bip_create_socket(&sin);
    if (BIP_Socket < 0) {
        return false;
    }
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = BIP_Port;
    sin.sin_addr = BIP_Broadcast_Binding_Address_Override
        ? BIP_Broadcast_Binding_Address
        : BIP_Broadcast_Addr;
    if (sin.sin_addr.s_addr == BIP_Address.s_addr) {
        BIP_Broadcast_Socket = BIP_Socket;
    } else {
        BIP_Broadcast_Socket = bip_create_socket(&sin);
        if (BIP_Broadcast_Socket < 0) {
            /* some platforms refuse to bind a directed broadcast address */
            sin.sin_addr.s_addr = htonl(INADDR_ANY);
            BIP_Broadcast_Socket = bip_create_socket(&sin);
        }
        if (BIP_Broadcast_Socket < 0) {
            bip_cleanup();
            return false;
        }
    }
    bvlc_init();
    return true;
}

bool bip_valid(void)
{
    return BIP_Socket >= 0;
}

void bip_cleanup(void)
{
    if (BIP_Broadcast_Socket >= 0 && BIP_Broadcast_Socket != BIP_Socket) {
        close(BIP_Broadcast_Socket);
    }
    if (BIP_Socket >= 0) {
        close(BIP_Socket);
    }
    BIP_Socket = -1;
    BIP_Broadcast_Socket = -1;
}

/* ---- millisecond timer ---------------------------------------------- */

static struct timespec Timer_Start;
static bool Timer_Started;

unsigned long mstimer_now(void)
{
    struct timespec now;

    if (!Timer_Started) {
        mstimer_init();
    }
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (unsigned long)((now.tv_sec - Timer_Start.tv_sec) * 1000L +
                           (now.tv_nsec - Timer_Start.tv_nsec) / 1000000L);
}

void mstimer_init(void)
{
    clock_gettime(CLOCK_MONOTONIC, &Timer_Start);
    Timer_Started = true;
}

/* ---- local date and time ------------------------------------------- */

/* offset (milliseconds) applied by TimeSynchronization */
static int64_t Time_Offset_Ms;

void datetime_timesync(BACNET_DATE *bdate, BACNET_TIME *btime, bool utc)
{
    struct tm tm_value;
    struct timeval now;
    time_t requested;

    if (!bdate || !btime) {
        return;
    }
    memset(&tm_value, 0, sizeof(tm_value));
    tm_value.tm_year = bdate->year - 1900;
    tm_value.tm_mon = bdate->month - 1;
    tm_value.tm_mday = bdate->day;
    tm_value.tm_hour = btime->hour;
    tm_value.tm_min = btime->min;
    tm_value.tm_sec = btime->sec;
    tm_value.tm_isdst = -1;
    requested = utc ? timegm(&tm_value) : mktime(&tm_value);
    if (requested == (time_t)-1 || gettimeofday(&now, NULL) != 0) {
        return;
    }
    Time_Offset_Ms = ((int64_t)requested - (int64_t)now.tv_sec) * 1000 +
        (int64_t)btime->hundredths * 10 - now.tv_usec / 1000;
}

bool datetime_local(
    BACNET_DATE *bdate,
    BACNET_TIME *btime,
    int16_t *utc_offset_minutes,
    bool *dst_active)
{
    struct timeval tv;
    struct tm tm_value;
    int64_t ms;
    time_t seconds;

    if (gettimeofday(&tv, NULL) != 0) {
        return false;
    }
    ms = (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000 + Time_Offset_Ms;
    seconds = (time_t)(ms / 1000);
    if (!localtime_r(&seconds, &tm_value)) {
        return false;
    }
    if (bdate) {
        datetime_set_date(
            bdate, (uint16_t)(tm_value.tm_year + 1900),
            (uint8_t)(tm_value.tm_mon + 1), (uint8_t)tm_value.tm_mday);
    }
    if (btime) {
        datetime_set_time(
            btime, (uint8_t)tm_value.tm_hour, (uint8_t)tm_value.tm_min,
            (uint8_t)tm_value.tm_sec, (uint8_t)((ms % 1000) / 10));
    }
    if (dst_active) {
        *dst_active = tm_value.tm_isdst > 0;
    }
    if (utc_offset_minutes) {
        /* BACnet UTC_Offset: minutes WEST of UTC, without DST */
        long east = (long)tm_value.tm_gmtoff;
        if (tm_value.tm_isdst > 0) {
            east -= 3600;
        }
        *utc_offset_minutes = (int16_t)(-east / 60);
    }
    return true;
}

void datetime_init(void)
{
    Time_Offset_Ms = 0;
}

#endif /* !_WIN32 */
