#!/usr/bin/env bash
# Build Whirr.app — a proper macOS .app bundle with Info.plist (LSUIElement=true)
# so it runs as a menu bar agent with no dock icon.
#
# The whirr-sampler daemon is now bundled INSIDE the app at
# Contents/MacOS/whirr-sampler, registered via SMAppService.daemon at runtime.
# The old sudo-installed launchd path under /Library/LaunchDaemons/ remains
# available as scripts/install-sampler.sh for environments where Dev ID
# code-signing is unavailable.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Whirr"
BUILD_DIR=".build/release"
DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"

DAEMON_PLIST_NAME="com.athayworth.whirr.sampler.plist"

echo "→ Building release binaries..."
swift build -c release --product "${APP_NAME}"
swift build -c release --product whirr-sampler

echo "→ Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Library/LaunchDaemons"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${BUILD_DIR}/whirr-sampler" "${APP_BUNDLE}/Contents/MacOS/whirr-sampler"
cp "Sources/Whirr/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "Sources/Whirr/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "Sources/Whirr/Resources/${DAEMON_PLIST_NAME}" \
   "${APP_BUNDLE}/Contents/Library/LaunchDaemons/${DAEMON_PLIST_NAME}"

echo "→ Embedding Sparkle.framework..."
# Source: SPM-resolved Sparkle XCFramework, macOS slice. Stable path
# under .build/artifacts; survives clean builds.
SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_DST="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
ditto "${SPARKLE_SRC}" "${SPARKLE_DST}"

# SPM-built CLI executables don't get @executable_path/../Frameworks in
# their rpath, so the dynamic loader can't find Sparkle.framework once
# the binary is moved into an .app bundle. Add it. The `|| true` keeps
# rebuilds idempotent — if the rpath is already there from a prior run
# of the same binary, install_name_tool exits non-zero but harmlessly.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

echo "→ Codesigning (inside out)..."
# Sign nested binaries first, then the bundle as the outer seal. --options
# runtime makes the binaries eligible for notarization once a real Developer
# ID is wired in. --sign - is ad-hoc; swap for "Developer ID Application: ..."
# when you have a paid Apple Developer account set up.
#
# Sparkle's framework ships pre-signed by the Sparkle project's team, but
# under ad-hoc that team ID mismatches our outer signature and the loader
# refuses the framework. Re-sign every nested helper / XPC / dylib with
# our ad-hoc identity so the whole bundle is one consistent identity.
for nested in \
    "${SPARKLE_DST}/Versions/B/XPCServices/Downloader.xpc" \
    "${SPARKLE_DST}/Versions/B/XPCServices/Installer.xpc" \
    "${SPARKLE_DST}/Versions/B/Updater.app" \
    "${SPARKLE_DST}/Versions/B/Autoupdate" \
    "${SPARKLE_DST}/Versions/B/Sparkle"; do
    codesign --force --options runtime --timestamp=none --sign - "${nested}"
done
codesign --force --options runtime --timestamp=none --sign - "${SPARKLE_DST}"

codesign --force --options runtime --timestamp=none --sign - \
    "${APP_BUNDLE}/Contents/MacOS/whirr-sampler"
# Outer bundle gets the entitlements that disable Library Validation, so
# the loader will accept the bundled Sparkle.framework (different
# Identifier than the app). See Resources/Whirr.entitlements for why.
codesign --force --options runtime --timestamp=none --sign - \
    --entitlements "Sources/Whirr/Resources/Whirr.entitlements" \
    "${APP_BUNDLE}"

# Clear any quarantine attribute so launching the freshly-built app from
# this script doesn't trip Gatekeeper's "downloaded from internet" check.
xattr -dr com.apple.quarantine "${APP_BUNDLE}" 2>/dev/null || true

echo
echo "✓ Built ${APP_BUNDLE}"
echo
echo "Run it:           open ${APP_BUNDLE}"
echo "Install:          cp -R ${APP_BUNDLE} /Applications/"
echo "Auto-launch:      System Settings → General → Login Items → add ${APP_NAME}"
echo
echo "Advanced sampling (sees root processes): click 'Enable' in Whirr's menu,"
echo "then approve in System Settings → General → Login Items & Extensions."
echo
echo "Legacy fallback (no SMAppService approval required, requires sudo):"
echo "    sudo scripts/install-sampler.sh"
