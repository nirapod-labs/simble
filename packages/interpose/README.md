<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# interpose

The injected simulator dylib that routes a guest app's CoreBluetooth calls to the host.

It hooks the CoreBluetooth central surface with Objective-C runtime swizzling, holds a shadow
registry for the framework's opaque objects, and carries each operation to the helper over the
loopback transport, delivering host events back as the guest's delegate callbacks. Scan, connect,
service and characteristic discovery, read, write, notify, and RSSI are routed; the peripheral role
is not implemented. The dylib is a simulator slice, loaded only by a debug scheme and never by a
shipped app (see `SECURITY.md` for the fence).
