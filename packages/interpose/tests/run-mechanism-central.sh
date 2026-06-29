#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs
#
# The in-simulator central lane: the interposer slice, injected into a guest app booted in the
# iOS or watchOS Simulator, routes the guest's CoreBluetooth central calls to the helper, which
# drives the Mac's real radio and streams events back as the guest's delegate callbacks. This needs
# a booted simulator, the running helper with Bluetooth authorized, and a real BLE peripheral in
# range, so it runs on a self-hosted machine with Bluetooth, not in CI. It is not a CI gate.
#
# Usage: run-mechanism-central.sh [ios|watchos]
#   ios (default) builds the iphonesimulator slice and the SimBLEExample central.
#   watchos builds the watchsimulator slice and the SimBLEWatchExample central.
#
# Env:
#   SIMBLE_DEVICE   a simulator name or udid to use; else a booted one of the platform, else a
#                   default the script boots and shuts down on exit.
#   SIMBLE_TIMEOUT  per-wait timeout in seconds (default 30).
#
# Steps:
#   1. Preconditions: Xcode, xcrun simctl, xcodegen.
#   2. Build the interposer slice, the helper, and simblectl.
#   3. Pick or boot a simulator of the platform.
#   4. Build and install the central example into it.
#   5. Start the helper; it arms the booted sim and writes its discovery record. Bail if Bluetooth
#      is not authorized for the helper.
#   6. Confirm the bridge over simblectl status.
#   7. Launch the guest, capture its console, and assert a discovery line within the timeout.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO"

PLATFORM="${1:-ios}"
TIMEOUT="${SIMBLE_TIMEOUT:-30}"

case "$PLATFORM" in
  ios)
    BUILD_DIR="build-sim"
    SCHEME="SimBLEExample"
    BUNDLE_ID="dev.simble.SimBLEExample"
    SIM_SDK="iphonesimulator"
    DEST_PLATFORM="iOS Simulator"
    RUNTIME_TOKEN="iOS"
    DEFAULT_DEVICE="iPhone 16"
    ;;
  watchos)
    BUILD_DIR="build-watchsim"
    SCHEME="SimBLEWatchExample"
    BUNDLE_ID="dev.simble.SimBLEWatchExample"
    SIM_SDK="watchsimulator"
    DEST_PLATFORM="watchOS Simulator"
    RUNTIME_TOKEN="watchOS"
    DEFAULT_DEVICE="Apple Watch Series 10 (46mm)"
    ;;
  *)
    echo "usage: run-mechanism-central.sh [ios|watchos]" >&2
    exit 2
    ;;
esac

WORKDIR="$(mktemp -d)"
HELPER_LOG="$WORKDIR/helper.log"
GUEST_LOG="$WORKDIR/guest.log"
HELPER_PID=""
GUEST_PID=""
BOOTED_BY_SCRIPT=""
SIMBLECTL=""

# Kill the helper and the guest console, disarm the sim, clear the discovery record, and shut down
# the sim only when this script booted it. Runs on any exit.
cleanup() {
  local code=$?
  if [ -n "$GUEST_PID" ]; then kill "$GUEST_PID" 2>/dev/null || true; fi
  if [ -n "${UDID:-}" ]; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  if [ -n "$HELPER_PID" ]; then kill "$HELPER_PID" 2>/dev/null || true; fi
  if [ -n "$SIMBLECTL" ]; then "$SIMBLECTL" disarm >/dev/null 2>&1 || true; fi
  if [ -n "$BOOTED_BY_SCRIPT" ] && [ -n "${UDID:-}" ]; then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKDIR"
  exit "$code"
}
trap cleanup EXIT INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Wait until grep -q "$2" matches file "$1", or until "$3" seconds pass. Returns 0 on a match,
# 1 on timeout.
wait_for_line() {
  local file="$1" pattern="$2" timeout="$3" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if [ -f "$file" ] && grep -q "$pattern" "$file"; then return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Step 1: preconditions.
echo "== preconditions =="
xcode-select -p >/dev/null 2>&1 || fail "Xcode command-line tools not selected; run xcode-select --install or xcode-select -s."
command -v xcrun >/dev/null 2>&1 || fail "xcrun not found; install Xcode."
xcrun simctl help >/dev/null 2>&1 || fail "xcrun simctl unavailable; install Xcode and its simulators."
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen not found; install it (brew install xcodegen)."

# Step 2: build the slice, the helper, and simblectl.
echo "== build interposer slice ($BUILD_DIR) =="
make configure
cmake --build "$BUILD_DIR" -j || fail "interposer slice build failed for $PLATFORM."

echo "== build helper =="
( cd apps/helper && xcrun swift build ) || fail "helper build failed."
HELPER_BIN="$(cd apps/helper && xcrun swift build --show-bin-path)/simble-helper"
[ -x "$HELPER_BIN" ] || fail "helper binary not found at $HELPER_BIN."

echo "== build simblectl =="
( cd tools/simblectl && xcrun swift build ) || fail "simblectl build failed."
SIMBLECTL="$(cd tools/simblectl && xcrun swift build --show-bin-path)/simblectl"
[ -x "$SIMBLECTL" ] || fail "simblectl binary not found at $SIMBLECTL."

# A device udid from `simctl list devices` plain text, restricted to runtime sections matching
# token $1. With a name/udid in $2, match that device in any state; without, the first Booted one.
# Output is the first match, or empty.
select_device() {
  local token="$1" want="${2:-}"
  xcrun simctl list devices 2>/dev/null | awk -v token="$token" -v want="$want" '
    /^-- / { insection = (index($0, token) > 0); next }
    !insection { next }
    {
      if (match($0, /\(([0-9A-Fa-f-]{36})\)/)) {
        udid = substr($0, RSTART + 1, RLENGTH - 2)
      } else { next }
      booted = (index($0, "(Booted)") > 0)
      name = $0
      sub(/^[[:space:]]+/, "", name)
      sub(/ \([0-9A-Fa-f-]{36}\).*/, "", name)
      if (want == "") { if (booted) { print udid; exit } }
      else if (name == want || udid == want) { print udid; exit }
    }'
}

# Step 3: pick or boot a simulator of the platform.
echo "== select simulator =="
UDID=""
if [ -n "${SIMBLE_DEVICE:-}" ]; then
  UDID="$(select_device "$RUNTIME_TOKEN" "$SIMBLE_DEVICE")"
  [ -n "$UDID" ] || fail "SIMBLE_DEVICE '$SIMBLE_DEVICE' is not a $PLATFORM simulator."
else
  UDID="$(select_device "$RUNTIME_TOKEN")"
fi

if [ -z "$UDID" ]; then
  echo "no booted $PLATFORM simulator; booting $DEFAULT_DEVICE"
  UDID="$(xcrun simctl create "simble-$PLATFORM" "$DEFAULT_DEVICE" 2>/dev/null || true)"
  [ -n "$UDID" ] || fail "could not create a $PLATFORM simulator; check available device types (xcrun simctl list devicetypes) and runtimes."
  xcrun simctl boot "$UDID" || fail "could not boot simulator $UDID."
  BOOTED_BY_SCRIPT=1
fi

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
echo "using simulator $UDID"

# Step 4: build and install the central example.
echo "== build and install example ($SCHEME) =="
( cd examples/native && xcodegen generate >/dev/null ) || fail "xcodegen generate failed."
DERIVED="$WORKDIR/DerivedData"
( cd examples/native && xcodebuild build \
    -project SimBLEExample.xcodeproj -scheme "$SCHEME" \
    -sdk "$SIM_SDK" -destination "platform=$DEST_PLATFORM,id=$UDID" \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO >/dev/null ) \
  || fail "example build failed for $SCHEME."

APP_PATH="$(find "$DERIVED/Build/Products" -maxdepth 2 -name "$SCHEME.app" -print -quit)"
[ -n "$APP_PATH" ] || fail "built $SCHEME.app not found under $DERIVED."
bash scripts/fence-check.sh --bundle "$APP_PATH" || fail "fence rejected the built app bundle."
xcrun simctl install "$UDID" "$APP_PATH" || fail "simctl install failed."

# Step 5: start the helper; it arms the booted sim and writes its discovery record.
echo "== start helper =="
"$HELPER_BIN" >"$HELPER_LOG" 2>&1 &
HELPER_PID=$!

waited=0
while [ "$waited" -lt "$TIMEOUT" ]; do
  if grep -q '"ready":true' "$HELPER_LOG"; then break; fi
  if grep -q "not authorized" "$HELPER_LOG"; then
    echo "--- helper output ---" >&2
    cat "$HELPER_LOG" >&2
    fail "Bluetooth is not authorized for the helper. Grant it once interactively: run apps/helper (or the bundled host app) and approve the Bluetooth prompt, then retry."
  fi
  if ! kill -0 "$HELPER_PID" 2>/dev/null; then
    echo "--- helper output ---" >&2
    cat "$HELPER_LOG" >&2
    fail "helper exited before it became ready."
  fi
  sleep 1
  waited=$((waited + 1))
done
grep -q '"ready":true' "$HELPER_LOG" || fail "helper did not report ready within ${TIMEOUT}s."
echo "helper ready"

# Step 6: confirm the bridge.
echo "== confirm bridge =="
"$SIMBLECTL" status | grep -q '"running":true' || fail "simblectl status did not report the bridge running."
echo "bridge running"

# Step 7: launch the guest and assert a discovery line. SIMCTL_CHILD_SIMBLE_AUTOSCAN starts the
# central scanning on poweredOn, so this needs no tap.
echo "== launch guest and observe ($BUNDLE_ID) =="
SIMCTL_CHILD_SIMBLE_AUTOSCAN=1 \
  xcrun simctl launch --terminate-running-process --console-pty "$UDID" "$BUNDLE_ID" \
  >"$GUEST_LOG" 2>&1 &
GUEST_PID=$!

if wait_for_line "$GUEST_LOG" '\[simble-example\] Found ' "$TIMEOUT"; then
  echo "PASS: the guest central saw a peripheral through the bridge."
  grep '\[simble-example\]' "$GUEST_LOG" | tail -5
  exit 0
fi

echo "--- guest console ---" >&2
grep '\[simble-example\]' "$GUEST_LOG" >&2 || true
fail "no discovery within ${TIMEOUT}s. A real BLE peripheral must be advertising in range, and the guest scans on launch (SIMBLE_AUTOSCAN), or pair it with the peripheral lane."
