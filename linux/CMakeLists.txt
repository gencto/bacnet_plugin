cmake_minimum_required(VERSION 3.10)

project(bacnet_plugin)

set(BACNET_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native/bacnet-stack")

add_definitions(-DBACDL_BIP -DBACNET_STACK_STATIC_DEFINE -DPRINT_ENABLED=0)

include_directories(
    "${BACNET_DIR}/src"
    "${BACNET_DIR}/ports/linux"
)

file(GLOB BACNET_CORE_SOURCES "${BACNET_DIR}/src/bacnet/*.c")
file(GLOB_RECURSE BACNET_BASIC_SOURCES "${BACNET_DIR}/src/bacnet/basic/*.c")
list(FILTER BACNET_BASIC_SOURCES EXCLUDE REGEX "ucix\.c$")
list(FILTER BACNET_BASIC_SOURCES EXCLUDE REGEX "basic/bbmd6/.*")

set(BACNET_DATALINK_SOURCES
    "${BACNET_DIR}/src/bacnet/datalink/bvlc.c"
    "${BACNET_DIR}/src/bacnet/datalink/cobs.c"
    "${BACNET_DIR}/src/bacnet/datalink/datalink.c"
)

set(BACNET_PORT_SOURCES
    "${BACNET_DIR}/ports/linux/bip-init.c"
    "${BACNET_DIR}/ports/linux/datetime-init.c"
    "${BACNET_DIR}/ports/linux/mstimer-init.c"
)

add_library(bacnet_plugin SHARED
    ${BACNET_CORE_SOURCES}
    ${BACNET_BASIC_SOURCES}
    ${BACNET_DATALINK_SOURCES}
    ${BACNET_PORT_SOURCES}
    "${CMAKE_CURRENT_SOURCE_DIR}/../native/src/bacnet_plugin.c"
)

target_link_libraries(bacnet_plugin pthread)

set_target_properties(bacnet_plugin PROPERTIES
  OUTPUT_NAME "bacnet_plugin"
)

target_compile_definitions(bacnet_plugin PUBLIC FLUTTER_PLUGIN_IMPL)
