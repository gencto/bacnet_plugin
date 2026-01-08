#include "bacnet_plugin.h"
#include <setjmp.h>
#include <windows.h>
#include <stdio.h>

/* Global jump buffer to intercept exit() calls */
static jmp_buf g_exit_jmp;
static bool g_jmp_active = false;

/* 
 * Custom exit handler to prevent the native library from terminating the entire 
 * Flutter process. Redefined via CMake: -Dexit=bacnet_plugin_exit_handler
 */
#ifdef _WIN32
__declspec(dllexport)
#endif
void bacnet_plugin_exit_handler(int code)
{
    char buf[256];
    sprintf(buf, "BACnet Native Exit Intercepted: code %d\n", code);
    OutputDebugStringA(buf);
    
    if (g_jmp_active) {
        longjmp(g_exit_jmp, 1);
    }
    
    /* Fallback if jump is not active (should not happen in wrapped calls) */
    TerminateThread(GetCurrentThread(), code);
}

/* Wrapper to simplify calling Send_Write_Property_Multiple_Request */
uint8_t bacnet_plugin_send_write_property_multiple(
    uint32_t device_id,
    BACNET_WRITE_ACCESS_DATA *write_access_data)
{
    uint8_t result = 0;
    __try {
        g_jmp_active = true;
        if (setjmp(g_exit_jmp) == 0) {
            uint8_t pdu[MAX_APDU] = {0};
            result = Send_Write_Property_Multiple_Request(pdu, sizeof(pdu), device_id, write_access_data);
        } else {
            OutputDebugStringA("BACnet WPM: Intercepted exit()\n");
            result = 0;
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("BACnet WPM: Caught Access Violation/Crash!\n");
        result = 0;
    }
    g_jmp_active = false;
    return result;
}

uint8_t bacnet_plugin_send_read_range_request(
    uint32_t device_id,
    BACNET_READ_RANGE_DATA *read_range_data)
{
    uint8_t result = 0;
    __try {
        g_jmp_active = true;
        if (setjmp(g_exit_jmp) == 0) {
            result = Send_ReadRange_Request(device_id, read_range_data);
        } else {
            OutputDebugStringA("BACnet ReadRange: Intercepted exit()\n");
            result = 0;
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("BACnet ReadRange: Caught Access Violation/Crash!\n");
        result = 0;
    }
    g_jmp_active = false;
    return result;
}

bool bacnet_plugin_safe_bip_init(char *ifname)
{
    bool result = false;
    __try {
        g_jmp_active = true;
        if (setjmp(g_exit_jmp) == 0) {
            result = bip_init(ifname);
        } else {
            OutputDebugStringA("BACnet safe_bip_init: Intercepted exit()\n");
            result = false;
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("BACnet safe_bip_init: Caught Access Violation/Crash!\n");
        result = false;
    }
    g_jmp_active = false;
    return result;
}

bool bacnet_plugin_safe_datalink_init(char *ifname)
{
    bool result = false;
    __try {
        g_jmp_active = true;
        if (setjmp(g_exit_jmp) == 0) {
            result = datalink_init(ifname);
        } else {
            OutputDebugStringA("BACnet safe_datalink_init: Intercepted exit()\n");
            result = false;
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("BACnet safe_datalink_init: Caught Access Violation/Crash!\n");
        result = false;
    }
    g_jmp_active = false;
    return result;
}

int bacnet_plugin_safe_bip_receive(
    BACNET_ADDRESS *src,
    uint8_t *npdu,
    uint16_t max_npdu,
    unsigned timeout)
{
    int result = 0;
    __try {
        g_jmp_active = true;
        if (setjmp(g_exit_jmp) == 0) {
            result = bip_receive(src, npdu, max_npdu, timeout);
        } else {
            OutputDebugStringA("BACnet safe_bip_receive: Intercepted exit()\n");
            result = -1;
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("BACnet safe_bip_receive: Caught Access Violation/Crash!\n");
        result = -1;
    }
    g_jmp_active = false;
    return result;
}

void bacnet_plugin_safe_npdu_handler(
    BACNET_ADDRESS *src,
    uint8_t *npdu,
    uint16_t pdu_len)
{
    __try {
        g_jmp_active = true;
        if (setjmp(g_exit_jmp) == 0) {
            npdu_handler(src, npdu, pdu_len);
        } else {
            OutputDebugStringA("BACnet safe_npdu_handler: Intercepted exit()\n");
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("BACnet safe_npdu_handler: Caught Access Violation/Crash!\n");
    }
    g_jmp_active = false;
}
