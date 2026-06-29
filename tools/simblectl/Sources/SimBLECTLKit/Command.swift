// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

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

public enum SimBLECTL {
  /// The verbs reported in the usage error.
  static let commands = ["version", "sims", "disarm", "status"]

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

  /// Dispatch on the verb (argv[1]). `arming` is the simulator-control seam the device verbs
  /// use; `state` reads the helper's discovery record; `probe` runs the bridge round-trip.
  public static func handle(
    arguments: [String],
    arming: SimulatorArming = SimulatorArming(),
    state: () -> HelperState? = HelperState.read,
    probe: (HelperState) -> StatusProbe? = SimBLECTL.probeBridge
  ) -> CommandResult {
    switch arguments.dropFirst().first {
    case "version":
      return CommandResult(exitCode: 0, output: #"{"protocolVersion":\#(SimBLEProtocol.version)}"#)
    case "sims":
      return sims(arming)
    case "disarm":
      return disarm(arming)
    case "status":
      return status(state, probe)
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

  /// The JSON token for a platform.
  private static func platformName(_ platform: SimPlatform) -> String {
    switch platform {
    case .ios: "ios"
    case .watchos: "watchos"
    }
  }
}
