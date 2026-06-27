// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import Foundation
import SimBLEHelperKit
import SimBLEHostCore

#if canImport(Darwin)
  import Darwin
#endif

// The central bridge helper: own the Mac's Bluetooth central and answer GATT
// operations over an authenticated loopback channel. It mints a per-session
// capability token and gates every request on it, validated before the op is
// interpreted. No key material crosses the wire. Constructing a CBCentralManager
// without a granted authorization aborts, so the radio path runs only when
// authorization is allowedAlways (the bundled host); otherwise it prints status
// and exits, leaving the real radio to the bundled app.

let status = HelperStatus()
print("\(status.host.bridgeName) helper protocol v\(status.protocolVersion)")

guard CBManager.authorization == .allowedAlways else {
  FileHandle.standardError.write(Data(
    "simble-helper: Bluetooth not authorized for this process; run from the bundled host\n".utf8
  ))
  exit(0)
}

let token = CapabilityToken()
let central = CoreBluetoothCentral()
let listener = LoopbackListener(
  router: RequestRouter(service: CentralService(backend: central), gate: AuthGate(session: token))
)

do {
  let requested = ProcessInfo.processInfo.environment["SIMBLE_PORT"].flatMap { UInt16($0) } ?? 0
  try listener.start(port: requested)
} catch {
  FileHandle.standardError.write(Data("simble-helper: failed to start: \(error)\n".utf8))
  exit(1)
}

print("{\"ready\":true,\"port\":\(listener.port)}")
fflush(stdout)

RunLoop.current.run()
