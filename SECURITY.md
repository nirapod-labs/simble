<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# Security

SimBLE is a development tool for local simulator runs. It is not a production
Bluetooth stack, recovery authority, signer, key store, or wallet service.

## Boundary

The tool is intended to relay CoreBluetooth operations from a simulated app to a
developer's Mac over localhost. It must never hold private keys, recovery
secrets, signing shares, or funds.

## Current Status

The CoreBluetooth interposer (central and peripheral), the host service, the
helper, and the CLI are implemented. The release fence runs static checks across
schemes, xcconfigs, project artifacts, bundle contents, and the references to
the injection variable, not naming alone.

## Capability token

The helper mints a fresh 32-byte token from the system CSPRNG for each session.
Every request carries the token in the protocol's token field (key 7), and the
helper validates it, in constant time, before the operation is interpreted. A
local process without the token cannot drive the adapter: the operations and
commands that drive it are gated on the token, and an unauthorized request is
rejected before its op is read. The channel is loopback only, bound to
`127.0.0.1`. The interposer is a debug-only simulator slice held out of shipped
apps by the fence. No key material, pairing secret, or bonding record crosses
the bridge.

## Fence Invariant

The interposer must be simulator-only and loaded only by debug launch
configuration. A shipped app must not link the interposer, bundle it, or carry
`DYLD_INSERT_LIBRARIES`.

## Reporting

Use GitHub private vulnerability reporting for security issues in this
repository.
