#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs
#
# The in-simulator central lane: the interposer slice, injected into a guest app booted in the
# iOS Simulator, routes the guest's CoreBluetooth central calls to the helper, which drives the
# Mac's real radio and streams events back as the guest's delegate callbacks. This needs a booted
# simulator, the running helper, and a real BLE peripheral in range, so it runs on a self-hosted
# machine with Bluetooth, not in CI. It is not a CI gate.
#
# How it runs, once the pieces exist:
#   1. Build the iOS interposer slice:  make configure && cmake --build build-sim
#      The slice is build-sim/bin/simble-interpose.so, named simble-interpose.
#   2. Build and start the helper, which prints {"ready":true,"port":<port>} on stdout and exposes
#      the per-session capability token in lowercase hex through its session transport.
#   3. Boot a simulator and install a guest app that uses CoreBluetooth as a central.
#   4. Launch the guest with the slice injected and the helper pointed at, through the debug
#      scheme that sets, behind the fence (debug-only, allowlisted): the dyld insert list pointing
#      at the slice, SIMBLE_PORT at the helper port, and SIMBLE_TOKEN at the session token hex.
#   5. Drive the guest to scan, connect, discover, read, write, and subscribe; assert it sees the
#      real peripheral's advertisements and characteristic values through its own delegate.
#
# The radio-free half of this lane runs as host ctests (make test): the swizzle install and
# uninstall (hook_smoke), the shadow registry mint and fail-closed (shadow_registry), the
# passthrough invariant (passthrough), and the transport round-trip against an in-test loopback
# (client_roundtrip).
set -uo pipefail

echo "run-mechanism-central is the self-hosted in-simulator lane; it is not wired as a CI gate."
echo "See the header of this script for how it runs against a booted simulator and the helper."
exit 0
