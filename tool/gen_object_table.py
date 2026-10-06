#!/usr/bin/env python3
"""Generates native/src/bp_object_table.h from bacnet-stack's device.c.

The default object table of bacnet-stack contains object types whose Init()
creates fixed demo instances (Command, Access Control).
The plugin server must only expose objects created by the application, so it
uses a copy of the table without those types.

Run after updating the bacnet-stack submodule:
    python3 tool/gen_object_table.py
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEVICE_C = ROOT / "native/bacnet-stack/src/bacnet/basic/object/device.c"
OUTPUT = ROOT / "native/src/bp_object_table.h"

# object types with statically allocated demo instances
EXCLUDED = {
    "OBJECT_COMMAND",
    "OBJECT_ACCESS_CREDENTIAL",
    "OBJECT_ACCESS_DOOR",
    "OBJECT_ACCESS_POINT",
    "OBJECT_ACCESS_RIGHTS",
    "OBJECT_ACCESS_USER",
    "OBJECT_ACCESS_ZONE",
    "OBJECT_CREDENTIAL_DATA_INPUT",
}


# functions replaced in the entries of the table (object type -> {old: new})
REPLACED = {
    # bacnet-stack implements change-of-state reporting for binary inputs
    # and values but leaves it out of the default table
    "OBJECT_BINARY_INPUT": {
        "NULL /* Intrinsic Reporting */": "Binary_Input_Intrinsic_Reporting",
    },
    "OBJECT_BINARY_VALUE": {
        "NULL /* Intrinsic Reporting */": "Binary_Value_Intrinsic_Reporting",
    },
    # only the Notification Classes the application created exist
    # (native/src/bp_nc.c)
    "OBJECT_NOTIFICATION_CLASS": {
        "Notification_Class_Init,": "bp_nc_init,",
        "Notification_Class_Count,": "bp_nc_count,",
        "Notification_Class_Index_To_Instance,": "bp_nc_index_to_instance,",
        "Notification_Class_Valid_Instance,": "bp_nc_valid_instance,",
        "Notification_Class_Object_Name,": "bp_nc_object_name,",
        "Notification_Class_Read_Property,": "bp_nc_read_property,",
        # report changes of the recipients to the application
        "Notification_Class_Add_List_Element,": "bp_nc_add_list_element,",
        "Notification_Class_Remove_List_Element,": "bp_nc_remove_list_element,",
        "NULL /* Create */": "bp_nc_create",
        "NULL /* Delete */": "bp_nc_delete",
    },
    # Priority_For_Writing and marked writes of schedules
    # (native/src/bp_schedule.c)
    "OBJECT_SCHEDULE": {
        # Schedule_Object_Name reads the string it fills (uninitialized)
        "Schedule_Object_Name,": "bp_schedule_object_name,",
        "Schedule_Read_Property,": "bp_schedule_read_property,",
        "Schedule_Write_Property,": "bp_schedule_write_property,",
        "Schedule_Delete,": "bp_schedule_delete,",
        "Schedule_Timer /* Timer */": "bp_schedule_timer /* Timer */",
    },
    # backup and restore properties (native/src/bp_backup.c)
    "OBJECT_DEVICE": {
        "Device_Read_Property_Local,": "bp_device_read_property,",
        "Device_Property_Lists,": "bp_device_property_lists,",
    },
    # logs created by the application (native/src/bp_trendlog.c)
    "OBJECT_TRENDLOG": {
        "Trend_Log_Init,": "bp_tl_init,",
        "Trend_Log_Count,": "bp_tl_count,",
        "Trend_Log_Index_To_Instance,": "bp_tl_index_to_instance,",
        "Trend_Log_Valid_Instance,": "bp_tl_valid_instance,",
        "Trend_Log_Object_Name,": "bp_tl_object_name,",
        "Trend_Log_Read_Property,": "bp_tl_read_property,",
        "Trend_Log_Write_Property,": "bp_tl_write_property,",
        "Trend_Log_Property_Lists,": "bp_tl_property_lists,",
        "TrendLogGetRRInfo,": "bp_tl_rr_info,",
        "NULL /* Create */": "bp_tl_create",
        "NULL /* Delete */": "bp_tl_delete",
        "NULL /* Timer */": "bp_tl_timer /* Timer */",
        "Trend_Log_Writable_Property_List }": "bp_tl_writable_property_list }",
    },
    # Date_List writes (native/src/bp_schedule.c)
    "OBJECT_CALENDAR": {
        "Calendar_Write_Property,": "bp_calendar_write_property,",
    },
    # bacnet-stack implements dynamic creation of accumulators but leaves it
    # out of the default table (unlike the other control objects)
    "OBJECT_ACCUMULATOR": {
        "NULL /* Create */": "Accumulator_Create",
        "NULL /* Delete */": "Accumulator_Delete",
    },
    # the content of files is kept in memory (native/src/bp_files.c)
    "OBJECT_FILE": {
        "bacfile_read_property,": "bp_file_read_property,",
        "bacfile_write_property,": "bp_file_write_property,",
        "bacfile_create,": "bp_file_create,",
        "bacfile_delete,": "bp_file_delete,",
    },
}


def replace(object_type: str, text: str) -> str:
    for old, new in REPLACED.get(object_type, {}).items():
        if old not in text:
            raise SystemExit(f"{object_type}: '{old}' not found in device.c")
        text = text.replace(old, new)
    return text


def main() -> None:
    source = DEVICE_C.read_text()
    includes = re.findall(r'^#include "bacnet/basic/object/[^"]+"$', source, re.M)
    start = source.index("static object_functions_t Default_Object_Table[] = {")
    end = source.index("\n};", start)
    body = source[start:end].split("\n")[1:]

    out_lines = []
    entry = []
    depth = 0
    for line in body:
        stripped = line.strip()
        if depth == 0 and stripped.startswith("#"):
            out_lines.append(line)
            continue
        if depth == 0 and not stripped:
            continue
        entry.append(line)
        depth += line.count("{") - line.count("}")
        if depth == 0:
            text = "\n".join(entry)
            match = re.search(r"\{\s*(\w+)", text)
            if match is None or match.group(1) not in EXCLUDED:
                out_lines.append(replace(match.group(1) if match else "", text))
            entry = []

    header = [
        "/* Generated by tool/gen_object_table.py from bacnet-stack device.c."
        " Do not edit. */",
        "#ifndef BP_OBJECT_TABLE_H",
        "#define BP_OBJECT_TABLE_H",
        "",
        *includes,
        '#include "bp_internal.h"',
        "",
        "static object_functions_t BP_Object_Table[] = {",
        *out_lines,
        "};",
        "",
        "#endif",
        "",
    ]
    OUTPUT.write_text("\n".join(header))
    print(f"wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
