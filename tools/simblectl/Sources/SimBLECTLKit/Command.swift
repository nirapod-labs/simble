// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

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
  public static func handle(arguments: [String]) -> CommandResult {
    if arguments.dropFirst().first == "version" {
      return CommandResult(exitCode: 0, output: #"{"protocolVersion":\#(SimBLEProtocol.version)}"#)
    }

    return CommandResult(exitCode: 0, output: #"{"name":"simblectl"}"#)
  }
}
