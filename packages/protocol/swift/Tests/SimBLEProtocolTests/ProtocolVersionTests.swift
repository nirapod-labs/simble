// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import SimBLEProtocol
import XCTest

final class ProtocolVersionTests: XCTestCase {
  func testVersionIsOne() {
    XCTAssertEqual(SimBLEProtocol.version, 1)
  }
}
