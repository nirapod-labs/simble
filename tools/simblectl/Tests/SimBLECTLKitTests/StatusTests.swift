// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLECTLKit
@testable import SimBLEHelperKit
import XCTest

/// The `status` verb driven through its state-reader and prober seams, with no real helper
/// or socket: no record reports not-running, a record plus a probe reports the bridge, and a
/// failed probe clears the stale record and reports not-running.
final class StatusTests: XCTestCase {
  private let record = HelperState(port: 51234, token: String(repeating: "ab", count: 32))

  func testStatusWithNoRecordReportsNotRunning() {
    let result = SimBLECTL.handle(
      arguments: ["simblectl", "status"], state: { nil }, probe: { _ in nil }
    )
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.output, #"{"running":false}"#)
  }

  func testStatusWithRecordAndProbeReportsRunning() {
    let result = SimBLECTL.handle(
      arguments: ["simblectl", "status"], state: { self.record },
      probe: { _ in StatusProbe(protocolVersion: 1) }
    )
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.output, #"{"running":true,"port":51234,"protocolVersion":1}"#)
  }

  func testStatusWithFailedProbeClearsTheRecordAndReportsNotRunning() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("simble-status-\(UUID().uuidString)", isDirectory: true)
    HelperState.directoryOverride = directory
    defer {
      HelperState.directoryOverride = nil
      try? FileManager.default.removeItem(at: directory)
    }
    try HelperState.write(port: record.port, token: record.token)

    let result = SimBLECTL.handle(
      arguments: ["simblectl", "status"], state: { self.record }, probe: { _ in nil }
    )
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.output, #"{"running":false}"#)
    XCTAssertNil(HelperState.read())
  }
}
