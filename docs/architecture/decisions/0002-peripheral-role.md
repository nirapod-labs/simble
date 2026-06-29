<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# 2. SimBLE peripheral role

Status: accepted

## Context

[ADR 0001](0001-simble-bridge-architecture.md) established the bridge for the central role: a
simulated app acting as a GATT client, scanning and connecting to real peripherals. The other half
of CoreBluetooth is the peripheral role, where the app is the server: it publishes a GATT service,
advertises it, and answers reads, writes, and subscriptions from a central.

That role is what an accessory's companion app, a peripheral simulator, or any app that advertises a
service exercises, and the Simulator cannot run it any more than it can run the central role. Leaving
it out would close half the gap the tool exists to remove.

## Decision

- **Implement the peripheral role symmetrically.** Hook `CBPeripheralManager` the way 0001 hooks
  `CBCentralManager`, and relay add-service, advertise, respond, and update-value to the host, which
  drives a real `CBPeripheralManager` on the Mac. A real external central discovers, connects, and
  exchanges GATT with the simulated app.
- **Reconstruct the peripheral delegate faithfully.** The interposer owns shadow
  `CBMutableService` and `CBMutableCharacteristic` objects and rebuilds the manager's callbacks
  (`didAdd`, `didStartAdvertising`, `didReceiveRead`, `didReceiveWrite`, `didSubscribeTo`,
  `didUnsubscribeFrom`, `isReadyToUpdateSubscribers`) on the app's queue, preserving CoreBluetooth's
  ordering.
- **One protocol, both roles.** The peripheral op set and its events ride the same length-prefixed
  CBOR channel from 0001; the host routes each command to the central or the peripheral service by
  its op, and both services deliver events over the one event channel.
- **watchOS peripheral is excluded.** Apple's watchOS SDK marks `CBPeripheralManager` unavailable,
  so the watch lane stays central-only and the peripheral role targets iOS.

## Consequences

- A simulated iOS app can advertise and serve GATT to a real external central, verified over the air
  against a real Android central.
- The interposer and the host each carry two manager families, and the protocol carries the
  peripheral op set in addition to the central one, so the codec parity surface is larger.
- The host runs a real `CBPeripheralManager`; one macOS Bluetooth grant covers both roles.

## Custody

The peripheral role moves Bluetooth traffic only. Serving a characteristic transports the
application's byte payloads, not key material; the app holds no recovery secret, signs nothing, and
touches no funds. Pairing and bonding stay excluded, so no long-term link key is derived. Custody
verdict: **PASS**.

## Alternatives considered

- **Central only, defer the peripheral role.** Leaves accessory and companion apps unable to test
  their advertising and GATT-server path in the Simulator, which is the same iteration cost 0001 set
  out to remove, now for the server side.
- **Emulate a peripheral in software.** A faked peripheral no real central can connect to fails the
  faithfulness constraint; kept only behind test interfaces for deterministic unit tests.
- **A watchOS peripheral shim.** The SDK symbol is unavailable on watchOS, so there is no faithful
  path; the role is excluded there rather than approximated.
