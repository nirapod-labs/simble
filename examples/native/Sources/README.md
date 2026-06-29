<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# Sources

The iOS example app with a Central tab and a Peripheral tab.

- `App.swift`: the `@main` app, a `TabView` over both roles, the launch-environment reading
  (`SIMBLE_AUTOSCAN`, `SIMBLE_AUTOADVERTISE`, `SIMBLE_TAB`), and the shared `LogLine` and `describe`
  helpers.
- `CentralView.swift`: the Central tab and `CentralScanner` (scan, connect, discover, read).
- `PeripheralView.swift`: the Peripheral tab and `PeripheralServer` (publish, advertise, serve reads,
  writes, and notifications).

Example code, not a CI gate.
