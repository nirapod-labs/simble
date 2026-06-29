<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# native examples

Three standalone CoreBluetooth apps. None import a SimBLE package; the interposer swizzles
CoreBluetooth at runtime when the SimBLE helper arms the booted simulator, so the apps' calls reach
the host Mac's radio.

- `Sources/` is an iOS central: scan, list peripherals by name and RSSI, connect to a tapped one,
  discover services and characteristics, and read the first readable characteristic.
- `Peripheral/` is an iOS peripheral: publish one service with one readable and notifiable
  characteristic, advertise a local name, serve reads and writes, and show subscription state.
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
xcodebuild -project SimBLEExample.xcodeproj -scheme SimBLEPeripheralExample -sdk iphonesimulator build
xcodebuild -project SimBLEExample.xcodeproj -scheme SimBLEWatchExample -sdk watchsimulator build
```

Run them in a booted simulator armed by the SimBLE helper. Example code, not a CI gate.
