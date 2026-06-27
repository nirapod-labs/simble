// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import SimBLECTLKit
import XCTest

final class CommandTests: XCTestCase {
  func testVersionCommandReturnsJson() {
    XCTAssertEqual(SimBLECTL.handle(arguments: ["simblectl", "version"]).output, #"{"protocolVersion":1}"#)
  }
}
