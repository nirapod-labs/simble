<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# simblectl

The JSON command-line client for SimBLE. Every verb prints one line of JSON to
stdout.

## Commands

- `version`: print the SimBLE protocol version.
- `sims`: list the booted simulators and their platforms.
- `disarm`: clear the injection environment on every booted simulator.
- `status`: report whether the bridge is running, over a HELLO round-trip to the recorded helper.
- `scan [seconds]`: scan on the running helper and print the discovered peripherals.
