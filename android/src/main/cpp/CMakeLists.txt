cmake_minimum_required(VERSION 3.4.1)

project(bacnet_plugin)

# Define the root of the bacnet-stack (relative to android/src/main/cpp)
set(BACNET_ROOT "../../../../native/bacnet-stack")

# Include directories
include_directories(
    ${BACNET_ROOT}/src
    ${BACNET_ROOT}/ports/linux
)

# 1. Core Sources
file(GLOB BACNET_CORE_SOURCES "${BACNET_ROOT}/src/bacnet/*.c")

# 2. Basic Services, Objects, and Handlers (Recursive)
file(GLOB_RECURSE BACNET_BASIC_SOURCES "${BACNET_ROOT}/src/bacnet/basic/*.c")
list(FILTER BACNET_BASIC_SOURCES EXCLUDE REGEX "ucix.c$")
list(FILTER BACNET_BASIC_SOURCES EXCLUDE REGEX "basic/bbmd6/.*")

# 3. Datalink (BACnet/IP)
set(BACNET_DATALINK_SOURCES
    "${BACNET_ROOT}/src/bacnet/datalink/bvlc.c"
    "${BACNET_ROOT}/src/bacnet/datalink/cobs.c"
    "${BACNET_ROOT}/src/bacnet/datalink/datalink.c"
)

# 4. Port Sources (Linux/Android)
file(GLOB BACNET_PORT_SOURCES "${BACNET_ROOT}/ports/linux/*.c")

add_library(bacnet_plugin SHARED
    ${BACNET_CORE_SOURCES}
    ${BACNET_BASIC_SOURCES}
    ${BACNET_DATALINK_SOURCES}
    ${BACNET_PORT_SOURCES}
)

# Defines for BACnet/IP
add_definitions(
    -DBACDL_BIP 
    -DPRINT_ENABLED=0 
    -DBACNET_STACK_STATIC
)

find_library(log-lib log)
target_link_libraries(bacnet_plugin ${log-lib})

