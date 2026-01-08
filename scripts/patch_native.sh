#!/bin/bash
set -e

# Path to the library
LIB_PATH="native/bacnet-stack"

if [ ! -d "$LIB_PATH" ]; then
    echo "Error: $LIB_PATH not found. Please clone the library first."
    exit 1
fi

echo "Patching BACnet Stack in $LIB_PATH..."

# 1. Patch win32/bip-init.c
# Replace exit(1) in bip_init_windows (void)
# Line context: print_last_error("TCP/IP stack initialization failed"); exit(1);
sed -i '/TCP\/IP stack initialization failed/{n;s/exit(1);/return;/}' "$LIB_PATH/ports/win32/bip-init.c"

# Replace exit(1) in gethostaddr (long)
# Context: print_last_error("gethostname"); exit(1);
sed -i '/print_last_error("gethostname")/{n;s/exit(1);/return 0;/}' "$LIB_PATH/ports/win32/bip-init.c"
# Context: print_last_error("gethostbyname"); exit(1);
sed -i '/print_last_error("gethostbyname")/{n;s/exit(1);/return 0;/}' "$LIB_PATH/ports/win32/bip-init.c"

# 2. Patch src/bacnet/datalink/dlenv.c
# Context: if (!datalink_init(pEnv)) { exit(1); }
# We use a more direct approach for dlenv.c as there might be multiple exit(1)
sed -i 's/exit(1);/return;/g' "$LIB_PATH/src/bacnet/datalink/dlenv.c"

echo "Patches applied successfully."
