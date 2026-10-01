/*
 * Internal helpers shared by the engine and the platform ports.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef BP_PORT_H
#define BP_PORT_H

/** Sets SO_RCVBUF/SO_SNDBUF for sockets created by bip_init(). 0 = default */
void bp_port_set_socket_buffer_size(int bytes);

#endif
