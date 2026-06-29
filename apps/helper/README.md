<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# helper

The macOS process that owns the CoreBluetooth bridge and arms booted simulators
with the matching interposer slice.

The SwiftPM command-line helper mints a per-session capability token, starts the
loopback listener, and arms every booted simulator whose platform has a built
interposer slice (`SimulatorArming`): it sets the slice insert path, the listener
port, and the token in the simulator's `launchd` environment via
`simctl spawn ... launchctl setenv`. It disarms on exit.

On startup it writes a `0600` state file (`HelperState`) holding its bound port and
capability token under the user application-support directory, and removes it on exit;
`simblectl status` reads it to probe the bridge.
