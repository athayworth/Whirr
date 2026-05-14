#!/usr/bin/env bash
# Install the whirr-sampler launchd daemon. Run with sudo.
#
# This is the ONLY step that requires root. The build itself runs as
# your user; this script just copies the artifact into place and
# registers a launchd daemon that runs as root.
#
# To uninstall, run scripts/uninstall-sampler.sh with sudo.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT_BIN="${REPO_ROOT}/.build/release/whirr-sampler"
PLIST_SRC="${REPO_ROOT}/scripts/com.whirr.sampler.plist"

BIN_DST="/usr/local/bin/whirr-sampler"
PLIST_DST="/Library/LaunchDaemons/com.whirr.sampler.plist"
DATA_DIR="/Library/Application Support/Whirr"

if [[ ! -f "$BUILT_BIN" ]]; then
    echo "Release binary missing at $BUILT_BIN" >&2
    echo "Build first (as your user, NOT root): swift build -c release --product whirr-sampler" >&2
    exit 1
fi

if [[ ! -f "$PLIST_SRC" ]]; then
    echo "Plist missing at $PLIST_SRC" >&2
    exit 1
fi

# Bootout any prior install so we don't end up with a stale binary linked
# from launchd while we copy the new one into place.
if launchctl print "system/com.whirr.sampler" >/dev/null 2>&1; then
    echo "→ Stopping existing daemon"
    launchctl bootout system "$PLIST_DST" || true
fi

echo "→ Installing binary to $BIN_DST"
install -m 0755 -o root -g wheel "$BUILT_BIN" "$BIN_DST"

echo "→ Creating $DATA_DIR"
mkdir -p "$DATA_DIR"
chown root:wheel "$DATA_DIR"
chmod 0755 "$DATA_DIR"

echo "→ Installing launchd plist to $PLIST_DST"
install -m 0644 -o root -g wheel "$PLIST_SRC" "$PLIST_DST"

echo "→ Loading daemon"
launchctl bootstrap system "$PLIST_DST"

# Give it a couple seconds to produce the first snapshot.
sleep 5
SNAPSHOT="${DATA_DIR}/snapshot.json"
if [[ -f "$SNAPSHOT" ]]; then
    echo
    echo "✓ Daemon running. First snapshot:"
    ls -la "$SNAPSHOT"
    echo
    echo "Logs: tail -f /var/log/whirr-sampler.log"
    echo "Stop: sudo $(dirname "$0")/uninstall-sampler.sh"
else
    echo
    echo "⚠ Daemon is loaded but hasn't produced a snapshot yet."
    echo "  Check /var/log/whirr-sampler.log for errors."
fi
