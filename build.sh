#!/usr/bin/env bash
# Build Whirr.app — a proper macOS .app bundle with Info.plist (LSUIElement=true)
# so it runs as a menu bar agent with no dock icon.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Whirr"
BUILD_DIR=".build/release"
DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"

echo "→ Building release binaries..."
swift build -c release --product "${APP_NAME}"
swift build -c release --product whirr-sampler

echo "→ Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Sources/Whirr/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

echo "→ Ad-hoc codesigning..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo
echo "✓ Built ${APP_BUNDLE}"
echo
echo "Run it:           open ${APP_BUNDLE}"
echo "Install:          cp -R ${APP_BUNDLE} /Applications/"
echo "Auto-launch:      System Settings → General → Login Items → add ${APP_NAME}"
echo
echo "Optional: install the privileged sampler daemon for root-process visibility:"
echo "    sudo scripts/install-sampler.sh"
