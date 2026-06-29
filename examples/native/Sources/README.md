<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# Sources

The iOS example app: a Central tab, a Peripheral tab, and a History tab over one shared console.

- `App.swift`: the `@main` app, the `TabView` and root wiring (toast overlay, success and error
  haptics), the launch-environment reading (`SIMBLE_AUTOSCAN`, `SIMBLE_AUTOADVERTISE`, `SIMBLE_TAB`,
  `SIMBLE_DEMO_SEED`), and the `launchFlag` helper.
- `BLEConsole.swift`: the unified `BLEConsole` that drives both roles, plus the `Toast`, `LogLine`,
  and `Discovery` values and the `describe` and `parseUUID` helpers.
- `Components.swift`: the toast view and `View.toast()`, the discovery row, and the history row.
- `Brand.swift`: the SimBLE lockup, the `brandHeader()` navigation modifier, and the About sheet.
- `Tabs.swift`: the Central, Peripheral, and History tabs.

Example code, not a CI gate.
