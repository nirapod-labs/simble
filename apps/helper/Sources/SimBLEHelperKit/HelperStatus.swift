// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import SimBLEHostCore
import SimBLEProtocol

public struct HelperStatus: Equatable, Sendable {
  public let host: HostStatus
  public let protocolVersion: Int

  public init(
    host: HostStatus = HostStatus(),
    protocolVersion: Int = SimBLEProtocol.version
  ) {
    self.host = host
    self.protocolVersion = protocolVersion
  }
}
