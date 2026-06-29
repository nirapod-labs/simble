<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

<p align="center">
  <strong>SimBLE</strong>
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/License-Apache_2.0-blue?style=flat-square"></a>
  <img alt="Swift" src="https://img.shields.io/badge/Swift-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="C" src="https://img.shields.io/badge/C-A8B9CC?style=flat-square&logo=c&logoColor=white">
  <img alt="Platforms: iOS and watchOS Simulators, macOS" src="https://img.shields.io/badge/Platforms-iOS_%C2%B7_watchOS_Sim_%C2%B7_macOS-lightgrey?style=flat-square&logo=apple&logoColor=white">
  <a href="https://github.com/nirapod-labs/simble/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/nirapod-labs/simble?style=flat-square&label=release&color=2563eb"></a>
  <a href="https://nirapod-labs.github.io/simble/"><img alt="Documentation" src="https://img.shields.io/badge/docs-architecture-2563eb?style=flat-square"></a>
</p>

# SimBLE

SimBLE gives the iOS and watchOS Simulators a real Bluetooth radio. It injects a small interposer into a simulated app, catches the CoreBluetooth calls, and routes them to your Mac's actual Bluetooth Low Energy adapter over a local channel. The app scans, connects, advertises, and serves GATT against real hardware, and the app itself imports nothing.

It exists because the iOS and watchOS Simulators have no Bluetooth radio. Anything that talks to a peripheral, a fitness sensor, a hardware wallet, a custom accessory, cannot run where you develop all day, so every change to a Bluetooth path forces you onto a physical device with a real peer in range. SimBLE bridges the Simulator to the Mac's radio so those paths run at your desk, behind a fence that keeps the bridge out of production.

## How it works

Your Mac has a Bluetooth radio. A menubar helper drives it. When a simulated app calls into CoreBluetooth, an injected interposer, loaded only through a debug scheme environment variable, relays the operation to the helper over an authenticated loopback socket. The helper runs it on the Mac's radio and streams the results and events back. The private radio state stays on the Mac; pairing and bonding are excluded, so no link key crosses the wire.

```
simulated app  ──CoreBluetooth──▶  interposer  ──loopback──▶  helper  ──▶  Mac Bluetooth radio
                                    (hook)       (CBOR+token)            (scan, connect, GATT)
     events, values  ◀──────────────────────────────────────────────────┘
```

The app's code does not change. The same `CBCentralManager` and `CBPeripheralManager` calls that reach the radio on a device reach the Mac's radio through SimBLE in the Simulator. Both roles work: a central scans, connects, reads, writes, and subscribes; a peripheral publishes a service and serves reads, writes, and notifications. The watchOS peripheral role is out of scope, because Apple's watchOS SDK marks `CBPeripheralManager` unavailable there.

## It can't ship

The interposer is built for the Simulator only. Apple will not load a simulator binary on a real device, and injecting into a signed app is blocked there regardless, so it cannot follow your code into production. The CI checks that keep it that way are in [SECURITY.md](SECURITY.md).

## See it run

A console app lives under [`examples/native`](examples/native): a SwiftUI app with a Central tab, a Peripheral tab, and a shared History tab, plus a standalone watchOS central. It scans and connects as a central, advertises and serves as a peripheral, and lands every operation in one history, all against the Mac's radio through SimBLE.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/nirapod-labs/simble/main/scripts/install.sh | sh
```

It builds from source and installs the menu bar helper to `/Applications` and the `simblectl` CLI to `~/.local/bin`. Needs Xcode. To build a specific release, set `SIMBLE_REF=v1.2.3`.

## Using it

Open SimBLE (it lives in the menu bar). It arms every booted simulator with the slice that matches its platform, iOS or watchOS, so the next app you launch is injected automatically and your existing CoreBluetooth code runs against the Mac's radio with nothing else to wire. To pin a specific Xcode scheme instead, copy the scheme environment from the menu and paste it into the scheme; it carries the loader, the port, and the token. The CLI mirrors the helper for a person or an agent, with JSON output and honest exit codes: `simblectl status` confirms the helper is live, `simblectl scan` lists nearby peripherals, `simblectl sims` lists booted simulators, and `simblectl disarm` clears the injection environment.

## Architecture

Three deployables and one shared contract, each in its own directory:

- [`packages/protocol`](packages/protocol) is the wire: one spec (length-prefixed CBOR) and two codecs, Swift for the helper and C for the interposer, that stay byte-for-byte compatible.
- [`packages/host-core`](packages/host-core) drives the Mac's Bluetooth radio through CoreBluetooth, in both the central and peripheral roles. The host side.
- [`packages/interpose`](packages/interpose) is the injected dylib. It hooks CoreBluetooth in the simulated app, redirects the operations to the helper, and passes everything else through.
- [`apps/helper`](apps/helper) is the menubar app that drives the radio and answers requests over loopback. It arms booted simulators automatically.
- [`tools/simblectl`](tools/simblectl) is the CLI, with JSON output and honest exit codes so a person or an agent can drive it.

Why an interposer and not a registered provider? CoreBluetooth is reached in-process, not through a device the OS enumerates, so the only way in is to intercept the calls inside the guest process. Inline hooking is the default because it is independent of the symbol-binding format, and the hook backend sits behind a seam so no single library is load-bearing.

## Repository layout

```
packages/
  protocol/        CBOR wire spec + Swift and C codecs
  host-core/       Swift, drives the Mac Bluetooth radio
  interpose/       the injected dylib (C), hooks CoreBluetooth
apps/
  helper/          the menubar app, drives the radio, serves loopback
tools/
  simblectl/       the JSON CLI
examples/
  native/          SwiftUI console (iOS + watchOS)
scripts/           fence checks, mechanism proofs, build helpers
docs/              architecture and development notes
```

## Developing

`make bootstrap` from a fresh clone, then `make build` and `make test`. The toolchain and every `make` target are in [docs/development.md](docs/development.md).

The Swift packages' tests need XCTest, so the `test` target runs them through the Xcode toolchain. To run one package directly:

```sh
cd packages/host-core
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

## Contributing

PR-driven. Branch off `main`, keep the change focused, open a pull request, and a maintainer reviews and merges. `main` is protected and rejects direct pushes. Conventional commits are enforced by commitlint, and the formatting and commit-message hooks run on commit.

## Security

SimBLE moves Bluetooth traffic only, on your own Mac's radio, in the Simulator, and never touches a real user's keys or funds. Pairing and bonding are excluded, so no link key crosses the wire. The threat model, the channel's authentication, and the fence are in [SECURITY.md](SECURITY.md). Found something security-relevant? Report it through GitHub's private vulnerability reporting.

## Who builds it

SimBLE is built by [Nirapod Labs](https://github.com/nirapod-labs). It came out of building Nirapod, a non-custodial wallet, where the paths worth exercising on every change reach a Bluetooth accessory the Simulator cannot talk to, so testing them meant reaching for a physical device every time. So we built the tool we wanted instead: a real Bluetooth radio in the Simulator, behind a fence that keeps it from following the code into production. It is useful to anyone whose iOS or watchOS app speaks Bluetooth Low Energy, which is why it is open source.

## License

Apache-2.0. See [LICENSE](LICENSE).
