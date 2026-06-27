// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import SimBLEHostCore
import XCTest

final class HostStatusTests: XCTestCase {
  func testDefaultStatusNamesBridge() {
    XCTAssertEqual(HostStatus().bridgeName, "SimBLE")
  }
}
