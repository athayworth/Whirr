#!/usr/bin/env bash
# Remove the whirr-sampler launchd daemon and all installed files.
# Run with sudo.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

BIN_DST="/usr/local/bin/whirr-sampler"
PLIST_DST="/Library/LaunchDaemons/com.whirr.sampler.plist"
DATA_DIR="/Library/Application Support/Whirr"
LOG_PATH="/var/log/whirr-sampler.log"

if launchctl print "system/com.whirr.sampler" >/dev/null 2>&1; then
    echo "→ Stopping daemon"
    launchctl bootout system "$PLIST_DST" || true
fi

if [[ -f "$PLIST_DST" ]]; then
    echo "→ Removing $PLIST_DST"
    rm "$PLIST_DST"
fi

if [[ -f "$BIN_DST" ]]; then
    echo "→ Removing $BIN_DST"
    rm "$BIN_DST"
fi

# Leave $DATA_DIR alone unless empty — it may be expected by other tooling.
# The snapshot file is small and harmless.
if [[ -d "$DATA_DIR" ]]; then
    rm -f "$DATA_DIR/snapshot.json" "$DATA_DIR/snapshot.json.tmp"
    rmdir "$DATA_DIR" 2>/dev/null || true
fi

if [[ -f "$LOG_PATH" ]]; then
    echo "→ Removing $LOG_PATH"
    rm "$LOG_PATH"
fi

echo "✓ whirr-sampler uninstalled."
