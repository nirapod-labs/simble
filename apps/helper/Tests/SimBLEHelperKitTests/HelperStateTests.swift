// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHelperKit
import XCTest

/// The helper's discovery record written, read back, and removed against a temporary
/// directory: the round-trip preserves the port and token, the file is `0600`, and a
/// removed record reads back nil.
final class HelperStateTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("simble-state-\(UUID().uuidString)", isDirectory: true)
    HelperState.directoryOverride = directory
  }

  override func tearDownWithError() throws {
    HelperState.directoryOverride = nil
    try? FileManager.default.removeItem(at: directory)
  }

  func testWriteThenReadRoundTrips() throws {
    let token = String(repeating: "ab", count: 32)
    try HelperState.write(port: 51234, token: token)
    XCTAssertEqual(HelperState.read(), HelperState(port: 51234, token: token))
  }

  func testWriteEmitsCompactJson() throws {
    try HelperState.write(port: 42000, token: "deadbeef")
    let url = try HelperState.fileURL()
    let contents = try String(contentsOf: url, encoding: .utf8)
    XCTAssertEqual(contents, #"{"port":42000,"token":"deadbeef"}"#)
  }

  func testWriteSetsOwnerOnlyPermissions() throws {
    try HelperState.write(port: 42000, token: "deadbeef")
    let url = try HelperState.fileURL()
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.int16Value, 0o600)
  }

  func testRemoveLeavesNilRead() throws {
    try HelperState.write(port: 1, token: "00")
    HelperState.remove()
    XCTAssertNil(HelperState.read())
  }

  func testReadIsNilWhenAbsent() {
    XCTAssertNil(HelperState.read())
  }

  func testRemoveIsHarmlessWhenAbsent() {
    HelperState.remove()
    XCTAssertNil(HelperState.read())
  }
}
