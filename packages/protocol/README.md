<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# protocol

The wire contract between the CoreBluetooth interposer and the host helper: CBOR
messages with a 4-byte length prefix. `SPEC.md` is the prose source of truth,
`protocol.cddl` the machine-checkable schema, `VERSION` the single protocol
version.

One spec, two codecs: Swift (`swift/`) for the helper, C (`c/`) for the
interposer, kept in agreement by emitting canonical CBOR and proven against each
other by the byte-parity vectors in both test suites. The wire carries three
frame kinds, told apart by the op in key 0: requests (guest to host, with the
capability token), responses (host to guest, with a status), and events (host to
guest, unsolicited, op in the 128-and-up range). It moves GATT operations and
byte payloads only; no key material crosses it.
