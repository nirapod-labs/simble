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

Hardware mechanism targets are declared as placeholders and are not implemented
yet.
