// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLEHelperKit
import SimBLEProtocol

public struct CommandResult: Equatable, Sendable {
  public let exitCode: Int32
  public let output: String

  public init(exitCode: Int32, output: String) {
    self.exitCode = exitCode
    self.output = output
  }
}

/// A successful bridge probe: the HELLO-negotiated protocol version.
public struct StatusProbe: Equatable, Sendable {
  /// The protocol version the bridge speaks.
  public let protocolVersion: UInt64

  public init(protocolVersion: UInt64) {
    self.protocolVersion = protocolVersion
  }
}

/// A peripheral a scan discovered: the peripheral id in lowercase hex, its last-seen RSSI,
/// and the advertised name and service UUIDs when present.
public struct DiscoveredDevice: Equatable, Sendable {
  /// The peripheral id as lowercase hex.
  public let peripheralId: String
  /// The last-seen RSSI in dBm.
  public let rssi: Int64
  /// The advertised local name, when present.
  public let localName: String?
  /// The advertised service UUIDs, when present.
  public let serviceUUIDs: [String]?

  public init(peripheralId: String, rssi: Int64, localName: String? = nil,
              serviceUUIDs: [String]? = nil)
  {
    self.peripheralId = peripheralId
    self.rssi = rssi
    self.localName = localName
    self.serviceUUIDs = serviceUUIDs
  }
}

public enum SimBLECTL {
  /// The verbs reported in the usage error.
  static let commands = ["version", "sims", "disarm", "status", "scan"]

  /// Probe the recorded bridge over a HELLO round-trip. Nil when the connection or the
  /// round-trip fails. The protocol version is the one HELLO negotiates.
  public static func probeBridge(_ state: HelperState) -> StatusProbe? {
    guard let token = CapabilityToken(hex: state.token),
          let client = try? LoopbackClient(port: state.port),
          case let .hello(version) = try? client.send(.hello(version: UInt64(SimBLEProtocol.version)),
                                                       token: token)
    else { return nil }
    return StatusProbe(protocolVersion: version)
  }

  /// Run a central scan on the recorded helper for `duration` seconds. Returns the discovered
  /// peripherals deduped by id with their last-seen fields, sorted by id, or empty on a connection
  /// or round-trip failure.
  public static func runScan(_ state: HelperState, _ duration: TimeInterval) -> [DiscoveredDevice] {
    guard let token = CapabilityToken(hex: state.token),
          let client = try? LoopbackClient(port: state.port),
          (try? client.send(.scanStart(serviceUUIDs: nil), token: token)) != nil
    else { return [] }
    var latest: [Data: DiscoveredDevice] = [:]
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
      guard case let .discovered(peripheralId, advertisement, rssi) = try? client.receiveEvent()
      else { continue }
      latest[peripheralId] = DiscoveredDevice(
        peripheralId: hex(peripheralId), rssi: rssi,
        localName: advertisement.localName, serviceUUIDs: advertisement.serviceUUIDs
      )
    }
    _ = try? client.send(.scanStop, token: token)
    return latest.values.sorted { $0.peripheralId < $1.peripheralId }
  }

  /// Dispatch on the verb (argv[1]). `arming` is the simulator-control seam the device verbs
  /// use; `state` reads the helper's discovery record; `probe` runs the bridge round-trip;
  /// `scan` runs a central scan on the recorded helper.
  public static func handle(
    arguments: [String],
    arming: SimulatorArming = SimulatorArming(),
    state: () -> HelperState? = HelperState.read,
    probe: (HelperState) -> StatusProbe? = SimBLECTL.probeBridge,
    scan: (HelperState, TimeInterval) -> [DiscoveredDevice] = SimBLECTL.runScan
  ) -> CommandResult {
    switch arguments.dropFirst().first {
    case "version":
      return CommandResult(
        exitCode: 0,
        output: #"{"version":"\#(simblectlVersion)","protocolVersion":\#(SimBLEProtocol.version)}"#)
    case "sims":
      return sims(arming)
    case "disarm":
      return disarm(arming)
    case "status":
      return status(state, probe)
    case "scan":
      return self.scan(arguments, state, scan)
    default:
      let list = commands.map { #""\#($0)""# }.joined(separator: ",")
      return CommandResult(exitCode: 1, output: #"{"error":"unknown command","commands":[\#(list)]}"#)
    }
  }

  /// Booted simulators as `{"sims":[{"udid":…,"platform":…},…]}`, sorted by udid.
  private static func sims(_ arming: SimulatorArming) -> CommandResult {
    let entries = arming.bootedSimulators().sorted { $0.udid < $1.udid }.map {
      #"{"udid":"\#($0.udid)","platform":"\#(platformName($0.platform))"}"#
    }
    return CommandResult(exitCode: 0, output: #"{"sims":[\#(entries.joined(separator: ","))]}"#)
  }

  /// Disarm every booted simulator and report the booted udids, sorted, as `{"disarmed":[…]}`.
  private static func disarm(_ arming: SimulatorArming) -> CommandResult {
    let udids = arming.bootedSimulators().map(\.udid).sorted()
    arming.disarm()
    let list = udids.map { #""\#($0)""# }.joined(separator: ",")
    return CommandResult(exitCode: 0, output: #"{"disarmed":[\#(list)]}"#)
  }

  /// The bridge's status. `{"running":false}` when no record exists. With a record, probe over
  /// HELLO: on success report the port and protocol version; on failure clear the stale record
  /// and report `{"running":false}`.
  private static func status(
    _ state: () -> HelperState?,
    _ probe: (HelperState) -> StatusProbe?
  ) -> CommandResult {
    guard let record = state() else {
      return CommandResult(exitCode: 0, output: #"{"running":false}"#)
    }
    guard let result = probe(record) else {
      HelperState.remove()
      return CommandResult(exitCode: 0, output: #"{"running":false}"#)
    }
    return CommandResult(
      exitCode: 0,
      output: #"{"running":true,"port":\#(record.port),"protocolVersion":\#(result.protocolVersion)}"#
    )
  }

  /// Default scan duration in seconds when `scan [seconds]` omits or mistypes the argument.
  private static let defaultScanDuration: TimeInterval = 5

  /// The discovered peripherals as `{"discovered":[…]}`. Exit 1 with `{"error":"no running
  /// helper"}` when no record exists. `scan [seconds]` sets the duration; absent or unparseable
  /// falls back to the default.
  private static func scan(
    _ arguments: [String],
    _ state: () -> HelperState?,
    _ scan: (HelperState, TimeInterval) -> [DiscoveredDevice]
  ) -> CommandResult {
    guard let record = state() else {
      return CommandResult(exitCode: 1, output: #"{"error":"no running helper"}"#)
    }
    let seconds = arguments.dropFirst(2).first.flatMap(TimeInterval.init) ?? defaultScanDuration
    let entries = scan(record, seconds).map(deviceJSON).joined(separator: ",")
    return CommandResult(exitCode: 0, output: #"{"discovered":[\#(entries)]}"#)
  }

  /// One discovered peripheral as a JSON object, omitting the absent optional fields.
  private static func deviceJSON(_ device: DiscoveredDevice) -> String {
    var fields = [#""peripheralId":"\#(device.peripheralId)""#, #""rssi":\#(device.rssi)"#]
    if let localName = device.localName {
      fields.append(#""localName":\#(jsonString(localName))"#)
    }
    if let serviceUUIDs = device.serviceUUIDs {
      let list = serviceUUIDs.map(jsonString).joined(separator: ",")
      fields.append(#""serviceUUIDs":[\#(list)]"#)
    }
    return "{\(fields.joined(separator: ","))}"
  }

  /// A string as a JSON string literal, escaping per the JSON grammar.
  private static func jsonString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let array = data.flatMap { String(data: $0, encoding: .utf8) }
    guard let array, array.hasPrefix("["), array.hasSuffix("]") else { return "\"\"" }
    return String(array.dropFirst().dropLast())
  }

  /// Lowercase hex of the bytes.
  private static func hex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// The JSON token for a platform.
  private static func platformName(_ platform: SimPlatform) -> String {
    switch platform {
    case .ios: "ios"
    case .watchos: "watchos"
    }
  }
}
