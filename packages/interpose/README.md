<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# interpose

The injected simulator dylib that routes a guest app's CoreBluetooth calls to the host.

It hooks the CoreBluetooth central and peripheral surfaces with Objective-C runtime swizzling, holds
a shadow registry for the framework's opaque objects, and carries each operation to the helper over
the loopback transport, delivering host events back as the guest's delegate callbacks. On the
central side: scan, connect, service and characteristic discovery, read, write, notify, and RSSI. On
the peripheral side: publish a service, advertise, respond to read and write requests, and notify
subscribers. The dylib is a simulator slice, loaded only by a debug scheme and never by a shipped
app (see `SECURITY.md` for the fence).
