<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# Architecture

SimBLE gives the iOS and watchOS Simulators real Bluetooth Low Energy by intercepting an app's
CoreBluetooth calls and relaying them to the host Mac's adapter over an authenticated loopback
channel.

- [SimBLE architecture](simble-architecture.qd): the interposer, the wire protocol, the host bridge,
  the trust boundary, the custody verdict, the fence, and v1 scope. Written in
  [Quarkdown](https://quarkdown.com).
- [Decision records](decisions/): the architectural decisions and their rationale.

For the development-only scope and the fence invariant, see [`SECURITY.md`](../../SECURITY.md).
