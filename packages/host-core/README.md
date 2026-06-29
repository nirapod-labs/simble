<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# host-core

The macOS CoreBluetooth service behind the helper.

It drives the Mac's adapter in both roles. As a central it scans, connects, discovers services and
characteristics, reads, writes, sets notify, and reads RSSI. As a peripheral it publishes services,
advertises, answers read and write requests, and pushes characteristic updates. Each role sits
behind a backend protocol, run against a fake on a radio-less runner or the real radio on a Mac.
