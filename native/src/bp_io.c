/*
 * bacnet_plugin - sockets: wakeup from other isolates, waiting for
 * traffic and socket options.
 *
 * SPDX-License-Identifier: MIT
 */
#if !defined(_WIN32)
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#endif

#include <string.h>

#include "bp_internal.h"
#include "bp_port.h"

#if defined(_WIN32)
typedef SOCKET bp_socket_t;
#define BP_INVALID_SOCKET INVALID_SOCKET
#define bp_close_socket closesocket
typedef volatile LONG bp_atomic_t;
#define bp_atomic_exchange(p, v) InterlockedExchange((p), (v))
#else
typedef int bp_socket_t;
#define BP_INVALID_SOCKET (-1)
#define bp_close_socket close
typedef volatile int bp_atomic_t;
#define bp_atomic_exchange(p, v) __atomic_exchange_n((p), (v), __ATOMIC_ACQ_REL)
#endif

static bp_socket_t g_wake_sock = BP_INVALID_SOCKET;
static struct sockaddr_in g_wake_addr;
static bp_atomic_t g_wake_pending;

static void bp_set_nonblocking(bp_socket_t sock)
{
#if defined(_WIN32)
    u_long mode = 1;
    ioctlsocket(sock, FIONBIO, &mode);
#else
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);
    }
    fcntl(sock, F_SETFD, FD_CLOEXEC);
#endif
}

bool bp_wake_init(void)
{
    bp_socket_t sock;
    struct sockaddr_in addr;
#if defined(_WIN32)
    int len = sizeof(addr);
#else
    socklen_t len = sizeof(addr);
#endif

    if (g_wake_sock != BP_INVALID_SOCKET) {
        return true;
    }
    sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == BP_INVALID_SOCKET) {
        return false;
    }
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        getsockname(sock, (struct sockaddr *)&addr, &len) != 0) {
        bp_close_socket(sock);
        return false;
    }
    bp_set_nonblocking(sock);
    g_wake_addr = addr;
    /* the socket is intentionally never closed: bacnet_plugin_wakeup() may
       race with shutdown from another thread */
    g_wake_sock = sock;
    return true;
}

void bp_wake_drain(void)
{
    char buffer[64];

    if (g_wake_sock == BP_INVALID_SOCKET) {
        return;
    }
    while (recv(g_wake_sock, buffer, sizeof(buffer), 0) > 0) { }
    /* clear after draining: a concurrent wakeup either left a datagram in
       the socket or its message is already queued for the caller */
    (void)bp_atomic_exchange(&g_wake_pending, 0);
}

BP_API void bacnet_plugin_wakeup(void)
{
    bp_socket_t sock = g_wake_sock;

    if (sock == BP_INVALID_SOCKET) {
        return;
    }
    if (bp_atomic_exchange(&g_wake_pending, 1) == 0) {
        (void)sendto(
            sock, "w", 1, 0, (const struct sockaddr *)&g_wake_addr,
            sizeof(g_wake_addr));
    }
}

void bp_wait(uint32_t timeout_ms)
{
#if !defined(_WIN32) && defined(BACDL_BIP6)
    int bip = bp_state.ipv6 ? bip6_get_socket() : bip_get_socket();
    int bcast = bp_state.ipv6 ? -1 : bip_get_broadcast_socket();
#else
    int bip = bip_get_socket();
    int bcast = bip_get_broadcast_socket();
#endif
#if defined(_WIN32)
    fd_set fds;
    struct timeval tv;

    FD_ZERO(&fds);
    if (bip >= 0) {
        FD_SET((SOCKET)bip, &fds);
    }
    if (bcast >= 0 && bcast != bip) {
        FD_SET((SOCKET)bcast, &fds);
    }
    if (g_wake_sock != BP_INVALID_SOCKET) {
        FD_SET(g_wake_sock, &fds);
    }
    tv.tv_sec = (long)(timeout_ms / 1000);
    tv.tv_usec = (long)((timeout_ms % 1000) * 1000);
    (void)select(0, &fds, NULL, NULL, &tv);
#else
    struct pollfd fds[3];
    nfds_t n = 0;

    if (bip >= 0) {
        fds[n].fd = bip;
        fds[n].events = POLLIN;
        fds[n++].revents = 0;
    }
    if (bcast >= 0 && bcast != bip) {
        fds[n].fd = bcast;
        fds[n].events = POLLIN;
        fds[n++].revents = 0;
    }
    if (g_wake_sock != BP_INVALID_SOCKET) {
        fds[n].fd = g_wake_sock;
        fds[n].events = POLLIN;
        fds[n++].revents = 0;
    }
    (void)poll(fds, n, (int)timeout_ms);
#endif
}

#if defined(_WIN32)
void bp_port_set_socket_buffer_size(int bytes)
{
    bp_state.socket_buffer_size = bytes;
}

void bp_apply_socket_buffer(int sock)
{
    if (sock >= 0 && bp_state.socket_buffer_size > 0) {
        int size = bp_state.socket_buffer_size;
        setsockopt(
            (SOCKET)sock, SOL_SOCKET, SO_RCVBUF, (const char *)&size,
            sizeof(size));
        setsockopt(
            (SOCKET)sock, SOL_SOCKET, SO_SNDBUF, (const char *)&size,
            sizeof(size));
    }
}
#endif
