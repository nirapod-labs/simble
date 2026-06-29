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

public enum SimBLECTL {
  /// The verbs reported in the usage error.
  static let commands = ["version", "sims", "disarm"]

  /// Dispatch on the verb (argv[1]). `arming` is the simulator-control seam the device verbs use.
  public static func handle(arguments: [String], arming: SimulatorArming = SimulatorArming()) -> CommandResult {
    switch arguments.dropFirst().first {
    case "version":
      return CommandResult(exitCode: 0, output: #"{"protocolVersion":\#(SimBLEProtocol.version)}"#)
    case "sims":
      return sims(arming)
    case "disarm":
      return disarm(arming)
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

  /// The JSON token for a platform.
  private static func platformName(_ platform: SimPlatform) -> String {
    switch platform {
    case .ios: "ios"
    case .watchos: "watchos"
    }
  }
}
