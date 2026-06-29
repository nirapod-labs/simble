// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import Foundation
import SimBLEHelperKit
import SimBLEHostCore
import SimBLEProtocol

#if canImport(Darwin)
  import Darwin
#endif

// The bridge helper: own the Mac's Bluetooth central and peripheral and answer GATT
// operations over an authenticated loopback channel. It mints a per-session
// capability token and gates every request on it, validated before the op is
// interpreted. No key material crosses the wire. Constructing the managers triggers
// the macOS authorization prompt on first run; the helper awaits poweredOn before
// arming and serving, and exits nonzero with a clear message on denial, an
// unsupported radio, a powered-off radio, or timeout.

// CBManagerState raw values.
let stateUnsupported: UInt64 = 2
let stateUnauthorized: UInt64 = 3
let statePoweredOff: UInt64 = 4

// Seconds to wait for the central to reach poweredOn; SIMBLE_BT_TIMEOUT overrides.
let authTimeout: TimeInterval = ProcessInfo.processInfo.environment["SIMBLE_BT_TIMEOUT"]
  .flatMap { TimeInterval($0) } ?? 15

func printError(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

let status = HelperStatus()
print("\(status.host.bridgeName) helper protocol v\(status.protocolVersion)")

let token = CapabilityToken()
let central = CoreBluetoothCentral()
let peripheral = CoreBluetoothPeripheral()

// Await the central reaching poweredOn (authorized, radio on). A terminal state
// (unsupported, unauthorized, poweredOff) bails early; otherwise poll to the deadline.
let deadline = Date().addingTimeInterval(authTimeout)
var state = central.managerState()
while state != Wire.managerStatePoweredOn, Date() < deadline {
  switch state {
  case stateUnsupported:
    printError("simble-helper: Bluetooth Low Energy is not supported on this Mac")
    exit(1)
  case stateUnauthorized:
    printError(
      "simble-helper: Bluetooth not authorized; grant simble-helper in "
        + "System Settings > Privacy & Security > Bluetooth, then retry"
    )
    exit(1)
  case statePoweredOff:
    printError("simble-helper: Bluetooth is off; turn Bluetooth on, then retry")
    exit(1)
  default:
    Thread.sleep(forTimeInterval: 0.1)
  }
  state = central.managerState()
}

guard state == Wire.managerStatePoweredOn else {
  printError(
    "simble-helper: timed out waiting for Bluetooth; the authorization prompt may be "
      + "pending, approve it and retry"
  )
  exit(1)
}

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
