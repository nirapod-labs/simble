<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# Tests

Portable C and Swift package tests run with `make test`. They cover the swizzle
install and uninstall, the shadow registry, the passthrough invariant, and the
transport round-trip, with no radio and no simulator.

## Mechanism lane

The mechanism lane runs a guest example app in the Simulator end to end: it
builds the interposer slice, starts the helper (which arms the booted simulator
and drives the Mac's radio), installs and launches the example, and reads the
guest's console to confirm a real radio event reached it.

```sh
make mechanism-ios             # iOS central: assert the guest sees a peripheral
make mechanism-watchos         # watchOS central: same, on the watch slice
make mechanism-peripheral-ios  # iOS peripheral: assert the guest engages advertising
```

Preconditions, checked by each script with a clear message when one is missing:

- Xcode and `xcrun simctl`, plus `xcodegen` to generate the example project.
- A simulator runtime for the platform. With none booted, the script boots a
  default device and shuts it down on exit.
- Bluetooth granted to the helper. The helper refuses to touch the radio without
  it; grant it once by running the helper (or the bundled host app) and
  approving the prompt.
- For the central lanes, a real BLE peripheral advertising in range. For the
  peripheral lane, confirming a separate central discovers the advertisement is
  a cross-device step (a phone, another Mac, or a second simulator running the
  central lane).

Set `SIMBLE_DEVICE` to a simulator name or udid to pick one; set `SIMBLE_TIMEOUT`
to change the per-wait timeout (default 30 seconds).

These lanes need Bluetooth and a peer, so they are operator-run, not CI gates.
The `ci-hardware` workflow runs `make mechanism-ios` on a self-hosted macOS
runner with Bluetooth, dispatched manually.
