// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

public struct HostStatus: Equatable, Sendable {
  public let bridgeName: String
  public let centralSupported: Bool
  public let peripheralSupported: Bool
  /// The host central manager's `CBManagerState` raw value, `0` (unknown) before a backend
  /// reports one. `centralSupported` is true when this reaches `poweredOn`.
  public let centralState: UInt64

  public init(
    bridgeName: String = "SimBLE",
    centralSupported: Bool = true,
    peripheralSupported: Bool = true,
    centralState: UInt64 = 0
  ) {
    self.bridgeName = bridgeName
    self.centralSupported = centralSupported
    self.peripheralSupported = peripheralSupported
    self.centralState = centralState
  }
}
