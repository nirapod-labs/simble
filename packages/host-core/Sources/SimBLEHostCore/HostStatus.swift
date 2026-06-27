// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

public struct HostStatus: Equatable, Sendable {
  public let bridgeName: String
  public let centralSupported: Bool
  public let peripheralSupported: Bool

  public init(
    bridgeName: String = "SimBLE",
    centralSupported: Bool = true,
    peripheralSupported: Bool = true
  ) {
    self.bridgeName = bridgeName
    self.centralSupported = centralSupported
    self.peripheralSupported = peripheralSupported
  }
}
