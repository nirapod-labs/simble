<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

<p align="center">
  <strong>SimBLE</strong>
</p>

<p align="center">
  Real Bluetooth Low Energy for the iOS and watchOS Simulators.
</p>

# SimBLE

SimBLE is a developer tool for routing CoreBluetooth work from the iOS and
watchOS Simulators to the Mac's real Bluetooth Low Energy adapter. It follows
the same repository shape as SimEnclave: a host helper, an injected simulator
interposer, a shared wire protocol, examples, tests, and a JSON CLI for agents
and humans.

The project is maintained by athexweb3 under Nirapod Labs.

## v1.0.0 target

- iOS Simulator central/client BLE.
- iOS Simulator peripheral/server BLE.
- watchOS Simulator central/client BLE.
- Real BLE devices through the Mac Bluetooth adapter.
- Debug-only injection with a release fence.

watchOS peripheral/server mode is out of scope for v1.0.0 because Apple's
watchOS SDK marks `CBPeripheralManager` unavailable there.

## Repository layout

```text
packages/
  protocol/        wire spec plus Swift and C codecs
  host-core/       macOS CoreBluetooth host service
  interpose/       simulator dylibs that hook CoreBluetooth
apps/
  helper/          SimBLE menu bar helper
tools/
  simblectl/       JSON CLI
examples/
  native/          iOS and standalone watchOS sample apps
  react-native/    Expo sample app
scripts/           fence, release, and install helpers
docs/              architecture and development notes
```

## Status

SimBLE gives the iOS and watchOS Simulators real Bluetooth Low Energy. It
injects a CoreBluetooth interposer into the guest app; the interposer relays
CoreBluetooth operations to a host helper that drives the Mac's radio over an
authenticated loopback channel. Both roles are implemented: the central (GATT
client) reaches real peripherals, and the peripheral (GATT server) publishes
services to real centrals. A JSON CLI (`simblectl`) drives and inspects the
bridge, and the example guest apps exercise each role.

## Run it end to end

The in-simulator radio path runs on a real Mac with Bluetooth granted to the
helper and a real BLE peer present. It is operator-run, not a CI gate.

One command:

```sh
make mechanism-ios
```

That target builds the interposer slice, the helper, and `simblectl`; picks or
boots an iOS simulator; builds and installs the central example into it; starts
the helper, which arms the booted simulator and records its discovery file; and
confirms the bridge over `simblectl status`. It needs Xcode, Bluetooth granted
to the helper, and a BLE peripheral advertising in range. `make
mechanism-watchos` runs the same lane for a watchOS central; `make
mechanism-peripheral-ios` runs the iOS peripheral lane.

Manual path:

```sh
make build                                              # build the C targets, interposer slice, and Swift packages
"$(cd apps/helper && swift build --show-bin-path)/simble-helper"   # start the helper; grant it Bluetooth on first run
"$(cd tools/simblectl && swift build --show-bin-path)/simblectl" status   # confirm the bridge is running
"$(cd tools/simblectl && swift build --show-bin-path)/simblectl" scan     # list nearby peripherals
```

The helper exits if Bluetooth is not authorized for it; grant it once
interactively, then retry. With the helper running and a simulator booted and
armed, run an example guest app (see
[examples/native](examples/native/README.md)) and its CoreBluetooth calls reach
the Mac's radio. `simblectl sims` lists booted simulators and `simblectl
disarm` clears the injection environment on every booted simulator.

## Development

```sh
make bootstrap
make build
make test
```

See [docs/development.md](docs/development.md) for the toolchain and commands.

## License

Apache-2.0. See [LICENSE](LICENSE).
