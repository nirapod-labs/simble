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

This is the repository scaffold. BLE routing, the wire protocol, and the
CoreBluetooth hooks are not implemented yet.

## Development

```sh
make bootstrap
make build
make test
```

See [docs/development.md](docs/development.md) for the toolchain and commands.

## License

Apache-2.0. See [LICENSE](LICENSE).
