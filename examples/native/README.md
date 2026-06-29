<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# native examples

Two standalone CoreBluetooth apps. Neither imports a SimBLE package; the interposer swizzles
CoreBluetooth at runtime when the SimBLE helper arms the booted simulator, so the apps' calls reach
the host Mac's radio.

- `Sources/` is the iOS app with two tabs:
  - Central: scan, list peripherals by name and RSSI, connect to a tapped one, discover services and
    characteristics, and read the first readable characteristic.
  - Peripheral: publish one service with one readable and notifiable characteristic, advertise a
    local name, serve reads and writes, and show subscription state.
- `Watch/` is a watchOS central: scan, connect to the first peripheral, and read its first readable
  characteristic.

## Build and run

Generate the Xcode project, then build a target. Run from this directory.

```sh
xcodegen generate
```

Open `SimBLEExample.xcodeproj` in Xcode and run a scheme, or build from the command line:

```sh
xcodebuild -project SimBLEExample.xcodeproj -scheme SimBLEExample -sdk iphonesimulator build
xcodebuild -project SimBLEExample.xcodeproj -scheme SimBLEWatchExample -sdk watchsimulator build
```

Run them in a booted simulator armed by the SimBLE helper. Example code, not a CI gate.

## Launch environment

The iOS app reads optional environment variables at startup, so a headless `simctl launch` can drive
it without a tap. Set them with `SIMCTL_CHILD_` prefixes through `simctl`.

- `SIMBLE_AUTOSCAN` set: the Central tab starts scanning when Bluetooth reaches powered on.
- `SIMBLE_AUTOADVERTISE` set: the Peripheral tab starts advertising when Bluetooth reaches powered on.
- `SIMBLE_TAB=peripheral`: open on the Peripheral tab (default Central).

```sh
xcrun simctl launch --console-pty \
  --env SIMBLE_AUTOSCAN=1 \
  <udid> dev.simble.SimBLEExample
```

With none set, the Scan and Advertise buttons drive both roles by hand.
