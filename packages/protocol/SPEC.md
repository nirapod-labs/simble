<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# Wire protocol

The contract between the interposer (inside a simulated app) and the helper (on
the host). The interposer hooks CoreBluetooth in the guest and forwards GATT
operations to the helper, which drives the Mac's real Bluetooth radio and relays
what it sees back. `protocol.cddl` is the machine-checkable companion to this
prose, and `VERSION` holds the single protocol version.

This is **version 1**. The wire carries GATT operations and byte payloads only.
No key material crosses it: there is no field for a private key, a pairing
secret, or a bonding record, so the bridge moves Bluetooth data and nothing a
device would protect in its own secure storage.

## Framing

Every message, both directions, is a length-prefixed frame:

```
+------------------+------------------------+
| length: u32 (BE) | payload: length bytes  |
+------------------+------------------------+
```

`length` is the CBOR payload size in bytes, big-endian, not counting the four
length bytes. A reader refuses any frame whose length exceeds `MAX_FRAME`
(1 MiB) and treats that as a protocol error rather than allocating.

There are three kinds of frame, told apart by the operation in key `0`:

- A **request** goes guest to host. It carries the capability token and no
  status, and its op is in the range 1 through 20.
- A **response** goes host to guest. It is the reply to a request, carries a
  status in key `1`, echoes the request's op in key `0`, and never carries the
  token.
- An **event** goes host to guest unsolicited. It carries neither the token nor a
  status, and its op is in the range 128 and up.

Most directed operations are synchronous request then response, with the result
in the response: the helper awaits the CoreBluetooth delegate callback internally
and answers when it fires. The things a central role learns without asking (a
scan result, a notification, an unexpected disconnect) and the things a
peripheral role is handed (an incoming read or write, a subscription) are events.

## Authentication

Every request carries the capability token in key `7`, a 32-byte byte string. The
helper mints one token per session, the developer's session is the only one that
can read it, and the interposer presents it on every call. The helper requires
exactly one key `7` of that length, compares it against the session token in
constant time, and rejects any request that does not match before it does
anything else, including before it interprets the operation in key `0`. The
decode rules in the Payload section, one value per key and shortest form and no
trailing bytes, are what make the token field unambiguous. A response and an
event never contain the token.

`HELLO` is authenticated too. There is no unauthenticated operation, so an
endpoint that cannot present the token cannot even probe the helper's version.

## Payload

The payload is a single CBOR map with unsigned-integer keys. Integer keys keep it
compact, and ascending order keeps the encoding canonical. Both codecs emit that
form, so the Swift helper and the C interposer agree byte for byte. Canonical is
a decode rule as much as an encode one: both codecs reject a map with duplicate
keys, reject any integer or length not in shortest form, and reject trailing
bytes after the map, so every message decodes to exactly one value per key. The
token in key `7` has to be uniquely defined by the bytes before it is checked.

The shared header keys (op, status, error, token, version, errorCode, appId,
appDisplayName) reuse the SimEnclave wire's numbers, so a reader of both
protocols sees the same key for the same idea. The BLE fields take clean integer
keys from 30 up. The keys:

| Key | Field                    | Direction      | Type                                            |
| --- | ------------------------ | -------------- | ----------------------------------------------- |
| 0   | `op`                     | all            | uint                                            |
| 1   | `status`                 | response       | uint, `0` OK or `1` ERROR                       |
| 6   | `error`                  | response       | tstr, human-readable reason, never load-bearing |
| 7   | `token`                  | request        | bstr (32), the capability token                 |
| 8   | `version`                | request, resp  | uint, HELLO only                                |
| 10  | `errorCode`              | response, evt  | int, a `CBError`/`CBATTError`-style code        |
| 14  | `appId`                  | request        | tstr, guest-reported bundle id, HELLO only      |
| 28  | `appDisplayName`         | request        | tstr, guest-reported display name, HELLO only   |
| 30  | `peripheralId`           | request, resp, evt | bstr, the host `CBPeripheral.identifier`    |
| 31  | `serviceUUID`            | request, resp, evt | tstr, a `CBUUID`                            |
| 32  | `characteristicUUID`     | request, resp, evt | tstr, a `CBUUID`                            |
| 33  | `value`                  | request, resp, evt | bstr, a characteristic value or write payload |
| 34  | `rssi`                   | response, evt  | int, signal strength in dBm                     |
| 35  | `localName`              | request, evt   | tstr, advertised local name                     |
| 36  | `advertisedServiceUUIDs` | request, evt   | array of tstr, advertised service UUIDs         |
| 37  | `txPower`                | event          | int, advertised TX power in dBm                 |
| 38  | `manufacturerData`       | event          | bstr, advertised manufacturer-specific data     |
| 39  | `writeType`              | request        | uint, `0` withResponse or `1` withoutResponse   |
| 40  | `notify`                 | request, resp  | uint, `0` or `1`                                |
| 41  | `managerState`           | response, evt  | uint, a `CBManagerState`                        |
| 42  | `requestId`              | request, evt   | uint, correlates a READ/WRITE_REQUEST to its RESPOND_* |
| 43  | `attOffset`              | event          | uint, the ATT offset of an incoming request     |
| 44  | `charProperties`         | request        | bstr, packed per-characteristic `CBCharacteristicProperties` |
| 45  | `attPermissions`         | request        | bstr, packed per-characteristic `CBAttributePermissions` |
| 46  | `isPrimary`              | request        | uint, `0` or `1`, a service's `isPrimary`       |
| 47  | `centralId`              | request, evt   | bstr, a subscribing or requesting central's id  |
| 48  | `mtu`                    | event          | uint, a central's `maximumUpdateValueLength`    |
| 49  | `attError`               | request        | uint, the ATT result code on a RESPOND_*        |
| 50  | `serviceUUIDs`           | request, resp  | array of tstr, a service-UUID list (filter or discovered) |
| 51  | `characteristicUUIDs`    | request, resp  | array of tstr, a characteristic-UUID list (filter or discovered) |

`writeType` is `0` for a write that expects a host acknowledgement and `1` for
one that does not. `notify` and `isPrimary` are `0` or `1`. `managerState` is a
`CBManagerState` raw value; `attError` and the ATT error on `errorCode` are ATT
result codes; the codes carried in `errorCode` are `CBError`/`CBATTError` raw
values for device parity. The reason in key `6` stays human-readable for logs and
is never load-bearing.

`charProperties` and `attPermissions` (keys 44, 45) are each a packed byte
string: a two-byte big-endian count, then one eight-byte big-endian value per
characteristic, positionally aligned with the characteristic UUID array in key
51. `ADD_SERVICE` carries the three arrays together, one entry per characteristic.

### Requests

Every request includes the token in key `7`. The examples below show it as
`<token>`.

`HELLO` negotiates the protocol version before any real work. The interposer
sends the version it speaks, and a mismatch comes back as an error, so a future
break is detected at the handshake rather than mid-operation. HELLO also carries
the connecting app's identity once, so the helper can show it: the bundle id (14)
and display name (28), both optional, both guest-reported, and both gating
nothing. The helper sanitizes the name before showing it.

```
{ 0: 1, 7: <token>, 8: 1, ? 14: <bundle id>, ? 28: <name> }
```

`CENTRAL_STATE` reads the host central manager's `CBManagerState`:

```
{ 0: 2, 7: <token> }
```

`SCAN_START` begins scanning, optionally filtered to a set of service UUIDs in
key 50; `SCAN_STOP` ends it:

```
{ 0: 3, 7: <token>, ? 50: [<service uuid>, ...] }
{ 0: 4, 7: <token> }
```

`CONNECT` and `DISCONNECT` name a peripheral by its host identifier in key 30:

```
{ 0: 5, 7: <token>, 30: <peripheral id> }
{ 0: 6, 7: <token>, 30: <peripheral id> }
```

`DISCOVER_SERVICES` and `DISCOVER_CHARACTERISTICS` walk the GATT database of a
connected peripheral, each optionally filtered:

```
{ 0: 7, 7: <token>, 30: <peripheral id>, ? 50: [<service uuid>, ...] }
{ 0: 8, 7: <token>, 30: <peripheral id>, 31: <service uuid>, ? 51: [<char uuid>, ...] }
```

`READ_CHARACTERISTIC` reads a value; `WRITE_CHARACTERISTIC` writes one with or
without a response; `SET_NOTIFY` enables or disables notifications (central role):

```
{ 0: 9,  7: <token>, 30: <peripheral id>, 31: <service uuid>, 32: <char uuid> }
{ 0: 10, 7: <token>, 30: <peripheral id>, 31: <service uuid>, 32: <char uuid>, 33: <value>, 39: <write type> }
{ 0: 11, 7: <token>, 30: <peripheral id>, 31: <service uuid>, 32: <char uuid>, 40: <0|1> }
```

`READ_RSSI` reads a connected peripheral's signal strength; `PERIPHERAL_STATE`
reads its `CBPeripheralState`:

```
{ 0: 12, 7: <token>, 30: <peripheral id> }
{ 0: 13, 7: <token>, 30: <peripheral id> }
```

`ADD_SERVICE` publishes a local GATT service with its characteristics (peripheral
role); `REMOVE_SERVICE` removes one:

```
{ 0: 14, 7: <token>, 31: <service uuid>, 44: <props>, 45: <perms>, 46: <0|1>, 51: [<char uuid>, ...] }
{ 0: 15, 7: <token>, 31: <service uuid> }
```

`START_ADVERTISING` begins advertising the local peripheral, optionally with a
local name and advertised service UUIDs; `STOP_ADVERTISING` ends it:

```
{ 0: 16, 7: <token>, ? 35: <local name>, ? 36: [<service uuid>, ...] }
{ 0: 17, 7: <token> }
```

`RESPOND_READ` and `RESPOND_WRITE` answer an incoming `READ_REQUEST` or
`WRITE_REQUEST` event (peripheral role), correlated by the request id in key 42,
with the ATT result in key 49:

```
{ 0: 18, 7: <token>, 33: <value>, 42: <request id>, 49: <att error> }
{ 0: 19, 7: <token>, 42: <request id>, 49: <att error> }
```

`UPDATE_VALUE` pushes a new value for a local characteristic to its subscribers,
or to one central when key 47 is present (peripheral role):

```
{ 0: 20, 7: <token>, 31: <service uuid>, 32: <char uuid>, 33: <value>, ? 47: <central id> }
```

### Responses

A response echoes the operation in key `0` and carries the status in key `1`. It
never carries a token. The synchronous operations carry their result; the rest
confirm with the status alone.

```
{ 0: 1,  1: 0, 8: 1 }                                              ; HELLO, version the helper speaks
{ 0: 2,  1: 0, 41: <manager state> }                              ; CENTRAL_STATE
{ 0: 3,  1: 0 }                                                   ; SCAN_START
{ 0: 4,  1: 0 }                                                   ; SCAN_STOP
{ 0: 5,  1: 0, 30: <peripheral id> }                             ; CONNECT
{ 0: 6,  1: 0, 30: <peripheral id> }                             ; DISCONNECT
{ 0: 7,  1: 0, 30: <peripheral id>, 50: [<service uuid>, ...] }  ; DISCOVER_SERVICES
{ 0: 8,  1: 0, 30: <peripheral id>, 31: <service uuid>, 51: [<char uuid>, ...] } ; DISCOVER_CHARACTERISTICS
{ 0: 9,  1: 0, 30: <peripheral id>, 31: <service uuid>, 32: <char uuid>, 33: <value> } ; READ_CHARACTERISTIC
{ 0: 10, 1: 0 }                                                  ; WRITE_CHARACTERISTIC
{ 0: 11, 1: 0, 30: <peripheral id>, 31: <service uuid>, 32: <char uuid>, 40: <0|1> } ; SET_NOTIFY
{ 0: 12, 1: 0, 30: <peripheral id>, 34: <rssi> }                ; READ_RSSI
{ 0: 13, 1: 0, 30: <peripheral id>, 41: <peripheral state> }    ; PERIPHERAL_STATE
{ 0: 14, 1: 0, 31: <service uuid> }                             ; ADD_SERVICE
{ 0: 15, 1: 0, 31: <service uuid> }                             ; REMOVE_SERVICE
{ 0: 16, 1: 0 }                                                  ; START_ADVERTISING
{ 0: 17, 1: 0 }                                                  ; STOP_ADVERTISING
{ 0: 18, 1: 0 }                                                  ; RESPOND_READ
{ 0: 19, 1: 0 }                                                  ; RESPOND_WRITE
{ 0: 20, 1: 0 }                                                  ; UPDATE_VALUE
```

A `WRITE_CHARACTERISTIC` response confirms the host accepted the request; for a
withoutResponse write that is all the wire promises. A `UPDATE_VALUE` response
confirms the value was sent. When the peripheral manager's transmit queue is full
the helper answers `UPDATE_VALUE` with an error instead, and raises a
`READY_TO_UPDATE` event when the queue drains.

An error echoes the failing op, sets status `1`, and carries a numeric code and a
human-readable reason:

```
{ 0: <op>, 1: 1, 6: "<reason>", 10: <cberror> }
```

`errorCode` is a `CBError` or `CBATTError` raw value, for device parity. The
reason in key `6` is human-readable, never load-bearing.

### Events

An event carries neither the token nor a status. Its op sits at 128 and up so a
reader tells it from a response at key `0`.

```
{ 0: 128, 30: <peripheral id>, 34: <rssi>, ? 35: <name>, ? 36: [<uuid>, ...], ? 37: <tx power>, ? 38: <mfg data> } ; DISCOVERED
{ 0: 129, 30: <peripheral id>, 31: <service uuid>, 32: <char uuid>, 33: <value> } ; CHAR_VALUE
{ 0: 130, ? 10: <cberror>, 30: <peripheral id> }                  ; DISCONNECTED
{ 0: 131, 41: <manager state> }                                   ; CENTRAL_STATE_CHANGED
{ 0: 132, 41: <manager state> }                                   ; PERIPHERAL_STATE_CHANGED
{ 0: 133, 31: <service uuid>, 32: <char uuid>, 42: <request id>, 43: <att offset>, 47: <central id> } ; READ_REQUEST
{ 0: 134, 31: <service uuid>, 32: <char uuid>, 33: <value>, 42: <request id>, 43: <att offset>, 47: <central id> } ; WRITE_REQUEST
{ 0: 135, 31: <service uuid>, 32: <char uuid>, 47: <central id>, 48: <mtu> } ; SUBSCRIBED
{ 0: 136, 31: <service uuid>, 32: <char uuid>, 47: <central id> } ; UNSUBSCRIBED
{ 0: 137 }                                                        ; READY_TO_UPDATE
```

`DISCOVERED` mirrors an advertisement dictionary: the peripheral id and RSSI are
always present, the rest of the advertisement is carried only when CoreBluetooth
surfaced it. `READ_REQUEST` and `WRITE_REQUEST` are the peripheral-role
counterparts the guest answers with `RESPOND_READ` and `RESPOND_WRITE`, matched by
the request id in key 42.

## Versioning

`VERSION` is a single integer, currently `1`, and the whole of version 1 is that
one number. `HELLO` negotiates it: the interposer announces the version it speaks,
the helper accepts or returns an error. A later wire break bumps `VERSION` and
both codecs move together. Because every message is a self-describing map, an
additive change, a new key or a new operation, does not need a bump as long as
the existing messages keep their bytes.

### Out of scope in version 1

Version 1 carries GATT operations and byte payloads only. It does not model
pairing or bonding, ANCS, L2CAP channels, full background-restoration fidelity,
or watchOS peripheral mode. Keeping key material and pairing state off the wire is
deliberate: nothing a device would hold in its own secure storage crosses the
bridge.

## Why CBOR and not a bare layout

A fixed binary layout would carry these fields too, but the message set is wide
(twenty commands and ten events, many with optional advertisement and discovery
fields) and a self-describing map absorbs that without versioned offsets, where a
hand-rolled layout would not. CBOR is a small, well-specified encoding. Each side
carries a compact hand-written codec, the Swift one in the helper and the C one
in the interposer, which byte-match because both emit the shortest form. The
surface stays small, the two remain each other's byte-for-byte oracle, and a
hand-written reader is where the duplicate-key and shortest-form rejection are
guaranteed directly rather than assumed of a library.
