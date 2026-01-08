cmake_minimum_required(VERSION 3.14)

project(bacnet_plugin)

# Define root relative to windows/ directory
set(BACNET_ROOT "../native/bacnet-stack")

include_directories(
    ${BACNET_ROOT}/src
    ${BACNET_ROOT}/ports/win32
)

# 1. Core Sources
file(GLOB BACNET_CORE_SOURCES "${BACNET_ROOT}/src/bacnet/*.c")

# 2. Basic Services, Objects, Clients
file(GLOB_RECURSE BACNET_BASIC_SOURCES 
    "${BACNET_ROOT}/src/bacnet/basic/*.c"
)

# Exclude specific non-IPv4 or conflicting files
list(FILTER BACNET_BASIC_SOURCES EXCLUDE REGEX "basic/bbmd6/.*")
list(FILTER BACNET_BASIC_SOURCES EXCLUDE REGEX "ucix.c")

# Exclude Client Device Object (Conflics with Server Device Object)
list(FILTER BACNET_BASIC_SOURCES EXCLUDE REGEX "device-client.c")

# Exclude alternative Server Device Object (Conflicts with standard Object Device)
list(FILTER BACNET_BASIC_SOURCES EXCLUDE REGEX "bacnet_device.c")

# Exclude basic datetime implementation (Conflicts with Win32 port)
list(FILTER BACNET_BASIC_SOURCES EXCLUDE REGEX "datetime_mstimer.c")

# Exclude Secure Connect (Requires Crypto/BSC)
list(FILTER BACNET_BASIC_SOURCES EXCLUDE REGEX "sc_netport.c")
list(FILTER BACNET_BASIC_SOURCES EXCLUDE REGEX "bsc/.*")

# 3. Datalink (IP - V4 ONLY + Dependencies)
set(BACNET_DATALINK_SOURCES
    "${BACNET_ROOT}/src/bacnet/datalink/bvlc.c"
    "${BACNET_ROOT}/src/bacnet/datalink/bvlc6.c"
    "${BACNET_ROOT}/src/bacnet/datalink/cobs.c"
    "${BACNET_ROOT}/src/bacnet/datalink/datalink.c"
    "${BACNET_ROOT}/src/bacnet/datalink/dlenv.c"
)

# 4. Port (Win32)
set(BACNET_PORT_SOURCES
    "${BACNET_ROOT}/ports/win32/bip-init.c"
    "${BACNET_ROOT}/ports/win32/mstimer-init.c"
    "${BACNET_ROOT}/ports/win32/datetime-init.c"
)

add_library(bacnet_plugin SHARED
    ${BACNET_CORE_SOURCES}
    ${BACNET_BASIC_SOURCES}
    ${BACNET_DATALINK_SOURCES}
    ${BACNET_PORT_SOURCES}
    "${CMAKE_CURRENT_SOURCE_DIR}/../native/src/bacnet_plugin.c"
)

target_compile_definitions(bacnet_plugin PRIVATE 
    BACDL_BIP 
    PRINT_ENABLED=0
    BACNET_IP_BROADCAST_USE_INADDR_ANY
    BACNET_STACK_STATIC_DEFINE
    _WINSOCK_DEPRECATED_NO_WARNINGS
    WIN32
    _WINDOWS
    # BACNET_CONFIG_H
)

set_target_properties(bacnet_plugin PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)

target_link_libraries(bacnet_plugin PRIVATE ws2_32)

set(bacnet_plugin_bundled_libraries
  "$<TARGET_FILE:bacnet_plugin>"
  PARENT_SCOPE
)
