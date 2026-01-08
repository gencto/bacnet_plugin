#ifndef BACNET_PLUGIN_H
#define BACNET_PLUGIN_H

#include <stdint.h>
#include <stdbool.h>

/* Include BACnet Stack headers */
#include "bacnet/bacdef.h"
#include "bacnet/bacenum.h"
#include "bacnet/bacstr.h"
#include "bacnet/bacerror.h"
#include "bacnet/bacapp.h"
#include "bacnet/basic/binding/address.h"
#include "bacnet/npdu.h"
#include "bacnet/basic/npdu/h_npdu.h"
#include "bacnet/apdu.h"
#include "bacnet/datalink/datalink.h"
#include "bacnet/basic/object/device.h"
#include "bacnet/basic/service/s_whois.h"
#include "bacnet/basic/service/s_iam.h"
#include "bacnet/basic/service/s_rp.h"
#include "bacnet/basic/service/s_wp.h"
#include "bacnet/basic/service/s_cov.h"
#include "bacnet/basic/service/s_wpm.h"
#include "bacnet/wpm.h"
#include "bacnet/basic/service/s_readrange.h"
#include "bacnet/readrange.h"

/* Forward declaration for the exit handler used in macro redirection */
#ifdef _WIN32
__declspec(dllexport)
#endif
void bacnet_plugin_exit_handler(int code);

/* Re-export WPM function just to be sure */
uint8_t bacnet_plugin_send_write_property_multiple(
    uint32_t device_id,
    BACNET_WRITE_ACCESS_DATA *write_access_data);

uint8_t bacnet_plugin_send_read_range_request(
    uint32_t device_id,
    BACNET_READ_RANGE_DATA *read_range_data);

/* Safe wrappers for initialization and processing */
bool bacnet_plugin_safe_bip_init(char *ifname);
bool bacnet_plugin_safe_datalink_init(char *ifname);
int bacnet_plugin_safe_bip_receive(
    BACNET_ADDRESS *src,
    uint8_t *npdu,
    uint16_t max_npdu,
    unsigned timeout);
void bacnet_plugin_safe_npdu_handler(
    BACNET_ADDRESS *src,
    uint8_t *npdu,
    uint16_t pdu_len);

#endif
