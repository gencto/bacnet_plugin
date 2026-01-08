#include "bacnet_plugin.h"

/* Wrapper to simplify calling Send_Write_Property_Multiple_Request */
uint8_t bacnet_plugin_send_write_property_multiple(
    uint32_t device_id,
    BACNET_WRITE_ACCESS_DATA *write_access_data)
{
    uint8_t pdu[MAX_APDU] = {0};
    /* Send_Write_Property_Multiple_Request(uint8_t *pdu, size_t max_pdu, uint32_t device_id, BACNET_WRITE_ACCESS_DATA *write_access_data) */
    return Send_Write_Property_Multiple_Request(pdu, sizeof(pdu), device_id, write_access_data);
}

uint8_t bacnet_plugin_send_read_range_request(
    uint32_t device_id,
    BACNET_READ_RANGE_DATA *read_range_data)
{
    /* Send_ReadRange_Request(uint32_t device_id, const BACNET_READ_RANGE_DATA *read_access_data) */
    /* Note: Send_ReadRange_Request uses internal buffer for PDU if needed or specific function? */
    /* Wait, s_readrange.c usually doesn't take PDU buffer in args? Let's check s_readrange.h signature again. */
    /* s_readrange.h: uint8_t Send_ReadRange_Request(uint32_t device_id, const BACNET_READ_RANGE_DATA *read_access_data); */
    /* Unlike WPM, it doesn't take PDU buffer? It must use internal buffer or allocate it. */
    return Send_ReadRange_Request(device_id, read_range_data);
}
