// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import SimBLEHelperKit
import XCTest

final class HelperStatusTests: XCTestCase {
  func testDefaultStatusUsesProtocolVersion() {
    XCTAssertEqual(HelperStatus().protocolVersion, 1)
  }
}
