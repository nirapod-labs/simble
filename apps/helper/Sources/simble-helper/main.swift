// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import Foundation
import SimBLEHelperKit
import SimBLEHostCore

#if canImport(Darwin)
  import Darwin
#endif

// The bridge helper: own the Mac's Bluetooth central and peripheral and answer GATT
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
let peripheral = CoreBluetoothPeripheral()
let listener = LoopbackListener(
  router: RequestRouter(
    service: CentralService(backend: central, peripheralSupported: true),
    peripheralService: PeripheralService(backend: peripheral),
    gate: AuthGate(session: token)
  )
)

do {
  let requested = ProcessInfo.processInfo.environment["SIMBLE_PORT"].flatMap { UInt16($0) } ?? 0
  try listener.start(port: requested)
} catch {
  FileHandle.standardError.write(Data("simble-helper: failed to start: \(error)\n".utf8))
  exit(1)
}

// SIGKILL skips disarm; the next arm overwrites the stale env.

let arming = SimulatorArming()
arming.armBooted(port: listener.port, token: token.hex)
try? HelperState.write(port: listener.port, token: token.hex)
atexit {
  SimulatorArming().disarm()
  HelperState.remove()
}
let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { number in
  signal(number, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
  source.setEventHandler {
    arming.disarm()
    HelperState.remove()
    exit(0)
  }
  source.resume()
  return source
}

print("{\"ready\":true,\"port\":\(listener.port)}")
fflush(stdout)

RunLoop.current.run()
