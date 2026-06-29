// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLECTLKit
import SimBLEHelperKit
import XCTest

/// The CLI dispatch with a fake simctl runner: the exact JSON each verb emits and the spawn
/// commands `disarm` issues. No real simulator runs here.
final class CommandTests: XCTestCase {
  /// Records every simctl invocation and serves a canned `list -j devices` payload.
  private final class FakeRunner: SimctlRunner, @unchecked Sendable {
    let listJSON: String
    private(set) var calls: [[String]] = []

    init(listJSON: String) {
      self.listJSON = listJSON
    }

    func run(_ args: [String]) -> (status: Int32, output: String) {
      calls.append(args)
      if args.first == "list" { return (0, listJSON) }
      return (0, "")
    }

    /// The spawn calls, dropping the `list` query.
    var envCalls: [[String]] {
      calls.filter { $0.first == "spawn" }
    }
  }

  /// Reports no slice for any platform, with no disk access.
  private struct NoSliceLocator: SliceLocator {
    func slicePath(for _: SimPlatform) -> String? { nil }
  }

  private func devices(_ entries: [(runtime: String, udid: String, state: String)]) -> String {
    var byRuntime: [String: [[String: String]]] = [:]
    for entry in entries {
      byRuntime[entry.runtime, default: []].append(["udid": entry.udid, "state": entry.state])
    }
    let root = ["devices": byRuntime]
    return String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
  }

  private let iosRuntime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
  private let watchRuntime = "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"

  private func arming(_ runner: FakeRunner) -> SimulatorArming {
    SimulatorArming(runner: runner, locator: NoSliceLocator())
  }

  func testVersionCommandReturnsJson() {
    XCTAssertEqual(SimBLECTL.handle(arguments: ["simblectl", "version"]).output, #"{"protocolVersion":1}"#)
  }

  func testSimsListsBootedIosAndWatchAndExcludesShutdown() {
    let runner = FakeRunner(listJSON: devices([
      (iosRuntime, "IOS-BOOT", "Booted"),
      (iosRuntime, "IOS-OFF", "Shutdown"),
      (watchRuntime, "WATCH-BOOT", "Booted"),
    ]))
    let result = SimBLECTL.handle(arguments: ["simblectl", "sims"], arming: arming(runner))
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(
      result.output,
      #"{"sims":[{"udid":"IOS-BOOT","platform":"ios"},{"udid":"WATCH-BOOT","platform":"watchos"}]}"#
    )
  }

  func testSimsWithNoneBootedReturnsEmptyArray() {
    let runner = FakeRunner(listJSON: devices([
      (iosRuntime, "IOS-OFF", "Shutdown"),
    ]))
    let result = SimBLECTL.handle(arguments: ["simblectl", "sims"], arming: arming(runner))
    XCTAssertEqual(result.output, #"{"sims":[]}"#)
  }

  func testDisarmReportsBootedUdidsAndUnsetsEnv() {
    let runner = FakeRunner(listJSON: devices([
      (iosRuntime, "IOS-BOOT", "Booted"),
      (watchRuntime, "WATCH-BOOT", "Booted"),
    ]))
    let result = SimBLECTL.handle(arguments: ["simblectl", "disarm"], arming: arming(runner))
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.output, #"{"disarmed":["IOS-BOOT","WATCH-BOOT"]}"#)
    // No slice is built here, so the shared insert list holds nothing of ours. Disarm clears only
    // the namespaced port and token; the unset set excludes the shared insert variable, which a
    // peer tool may own.
    for udid in ["IOS-BOOT", "WATCH-BOOT"] {
      let spawns = runner.envCalls.filter { $0.contains(udid) }
      let unset = Set(spawns
        .filter { $0.count >= 5 && $0.prefix(4) == ["spawn", udid, "launchctl", "unsetenv"] }
        .map { $0[4] })
      XCTAssertEqual(unset, ["SIMBLE_PORT", "SIMBLE_TOKEN"])
    }
  }

  func testUnknownVerbReturnsUsageError() {
    let result = SimBLECTL.handle(arguments: ["simblectl", "bogus"])
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertEqual(result.output, #"{"error":"unknown command","commands":["version","sims","disarm","status","scan"]}"#)
  }

  func testNoVerbReturnsUsageError() {
    let result = SimBLECTL.handle(arguments: ["simblectl"])
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertEqual(result.output, #"{"error":"unknown command","commands":["version","sims","disarm","status","scan"]}"#)
  }
}
