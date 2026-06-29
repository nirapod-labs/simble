<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# Development

SimBLE uses Swift for the helper and host packages, C for the interposer and
wire codec, and a small JavaScript workspace for formatting and hooks.

## Prerequisites

- macOS with Xcode.
- Homebrew.
- Node.js and pnpm.

## Setup

```sh
make bootstrap
```

## Commands

| Target | Purpose |
| --- | --- |
| `make build` | build C targets and Swift packages |
| `make test` | run C tests, Swift tests, and fence checks |
| `make test-portable` | run checks that do not need BLE hardware |
| `make fence` | run static fence checks |
| `make clean` | remove build outputs |

The `make mechanism-ios`, `make mechanism-watchos`, and `make
mechanism-peripheral-ios` targets run the real in-simulator lanes: the
interposer slice, injected into a guest app in a booted simulator, routes its
CoreBluetooth calls through the helper to the Mac's radio. They are
operator-run, not CI gates: each needs Xcode, a booted or bootable simulator,
Bluetooth granted to the helper, and (for the central lanes) a BLE peer in
range.
