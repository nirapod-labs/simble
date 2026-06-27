<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# 1. SimBLE bridge architecture

Status: accepted

## Context

The iOS and watchOS Simulators have no Bluetooth controller. CoreBluetooth comes up unsupported, so
scanning, connecting, GATT operations, and advertising cannot run. A team building a Bluetooth app
must therefore deploy to a physical device for every change that touches the radio, which is the
slowest part of the loop to iterate on.

SimBLE's goal is to let a simulated app exercise real Bluetooth Low Energy against live peripherals
while keeping the same source that runs on a device, and to do so as a development tool that can never
ship inside a product.

## Decision

- **Bridge by interposition.** There is no supported API to register a software Bluetooth adapter
  with CoreBluetooth, so the redirect is active interception inside the guest process: hook the
  CoreBluetooth calls the app makes and the callbacks the framework makes, and relay the operations
  to a host helper that drives the Mac's real adapter.
- **Objective-C runtime hooks.** CoreBluetooth is an Objective-C framework, so the interposer
  replaces method implementations at the runtime rather than binding private symbols. The interposer
  synthesizes shadow `CBPeripheral`, `CBService`, and `CBCharacteristic` objects and dispatches
  events to the app's delegate on its own queue, preserving CoreBluetooth's ordering and threading.
- **Authenticated loopback, length-prefixed CBOR.** The channel is a TCP socket on `127.0.0.1`
  authenticated by a 256-bit per-session token. Framing is a 4-byte big-endian length prefix plus a
  canonical, integer-keyed CBOR map. The protocol is bidirectional: command frames from the guest,
  event frames from the host.
- **Two byte-identical codecs.** A Swift codec (helper) and a C codec (interposer) encode the same
  logical message to the same bytes; parity is a test invariant.
- **Simulator-only, debug-only fence.** Each interposer is a simulator-slice binary, one per
  simulator platform, and reaches an app only through `DYLD_INSERT_LIBRARIES` set in a Debug scheme.
  CI enforces the fence; today that is the static naming and wiring checks, and the fence also
  defines a binary simulator-slice check that fails closed on any device platform.
- **Real adapter, not an emulator.** v1 targets a real Bluetooth adapter and live peripherals. Fake
  Bluetooth exists only behind test interfaces for deterministic unit tests.

## Consequences

- A simulated app sees real BLE: real scans, connections, GATT, notifications, and, on iOS, the
  peripheral role.
- The async, event-driven nature of CoreBluetooth makes the interposer more involved than a
  synchronous relay: it must own shadow objects and reconstruct delegate callbacks faithfully.
- The bridge's added cost is a microsecond-scale codec and one localhost round trip, dominated by the
  radio's connection interval, so latency tracks a device.
- The tool is structurally unable to run in a shipped app, which is the property that lets it be
  injected freely in development.

## Custody

SimBLE moves Bluetooth traffic only. It generates, stores, and transports no private keys, holds no
recovery secret, signs nothing, and touches no funds. Excluding pairing and bonding (which would
derive a long-term link key) keeps the wire to GATT operations and their application byte payloads.
Custody verdict: **PASS**.

## Alternatives considered

- **Registered virtual adapter.** No public CoreBluetooth API exists to supply a software controller,
  so this is not available.
- **Mock or record-and-replay CoreBluetooth.** Fakes the framework rather than the radio; it cannot
  reach a real peripheral and diverges from device behavior, failing the faithfulness constraint. Kept
  only behind test interfaces.
- **Remote control of a tethered physical device.** Keeps a device in the loop, which is the cost the
  tool exists to remove, and does not integrate with the Simulator workflow.
