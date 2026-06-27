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

This scaffold contains no CoreBluetooth interposer implementation. The release
fence currently runs static naming checks only.

## Fence Invariant

The interposer must be simulator-only and loaded only by debug launch
configuration. A shipped app must not link the interposer, bundle it, or carry
`DYLD_INSERT_LIBRARIES`.

## Reporting

Use GitHub private vulnerability reporting for security issues in this
repository.
