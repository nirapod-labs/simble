#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs
#
# Assemble the menubar helper into a SimBLE.app bundle and sign it. A bundle (not a bare
# executable) is what MenuBarExtra needs to render and what lets macOS attribute the
# Bluetooth grant to a stable identity. SIGN_ID defaults to ad-hoc; pass a keychain identity
# for a named local build.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SIGN_ID="${SIGN_ID:--}"
APP="$REPO/dist/SimBLE.app"
# The single version source. CFBundleShortVersionString must be a dotted-numeric string, so a
# prerelease tag (1.0.0-beta) is trimmed to its numeric core (1.0.0) for the plist.
VERSION="$(cat "$REPO/VERSION" 2>/dev/null || echo 0.0.0)"
SHORT_VERSION="${VERSION%%-*}"

echo "building simble-menubar (release)..."
( cd "$REPO/apps/helper" && xcrun swift build -c release --product simble-menubar ) || exit 1
BIN="$REPO/apps/helper/.build/release/simble-menubar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/simble-menubar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.simble.menubar</string>
  <key>CFBundleName</key><string>SimBLE</string>
  <key>CFBundleDisplayName</key><string>SimBLE</string>
  <key>CFBundleExecutable</key><string>simble-menubar</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>SimBLE bridges the iOS and watchOS Simulators to this Mac's Bluetooth radio.</string>
</dict>
</plist>
PLIST

# Bundle the interposers the helper injects, one per simulator platform. Each is a simulator-slice
# binary the fence keeps out of any shipped app; the helper carries them and arms a booted simulator
# with the slice matching its platform. Without these the installed helper finds no slice and arms
# nothing. Build, copy, and sign each into Resources before the bundle is sealed.
command -v cmake >/dev/null || { echo "cmake is required to build the interposers: brew install cmake"; exit 1; }
echo "building the interposers (ios and watchos sim slices)..."
( cd "$REPO" && make dylib ) || { echo "failed to build the interposers"; exit 1; }
for slice in build-sim/bin/simble-interpose.dylib build-watchsim/bin/simble-interpose-watchos.dylib; do
  [ -f "$REPO/$slice" ] || { echo "missing interposer slice: $slice (is the simulator SDK installed?)"; exit 1; }
  name="$(basename "$slice")"
  cp "$REPO/$slice" "$APP/Contents/Resources/$name"
  codesign -s "$SIGN_ID" --force --timestamp=none "$APP/Contents/Resources/$name" >/dev/null 2>&1 \
    || { echo "codesign failed for $name"; exit 1; }
done

# Ad-hoc sign the bundle so the Bluetooth grant attributes to a stable identity across runs.
# --deep covers any nested code; --force replaces an existing signature.
codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 \
  || { echo "codesign failed for identity '$SIGN_ID'"; exit 1; }

echo "built $APP (signed: $SIGN_ID)"
echo "run it:   open \"$APP\""
