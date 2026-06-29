<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# Watch

A standalone watchOS CoreBluetooth central: scan, connect to the first peripheral,
and read its first readable characteristic. `App.swift` is the whole app.

Run it in the watchOS Simulator. Start the SimBLE helper first so it arms the booted
watch sim; the app's CoreBluetooth calls then reach the host Mac's radio. On an Apple
Watch the same code drives the device radio. Example code, not a CI gate.
