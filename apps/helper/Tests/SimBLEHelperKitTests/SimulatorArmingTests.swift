// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHelperKit
import XCTest

/// The arming logic with a fake simctl runner and a fixed slice locator: the exact spawn commands
/// per platform, the skip of a no-slice platform, and the full disarm on every booted sim. No real
/// simulator runs here.
final class SimulatorArmingTests: XCTestCase {
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

    /// The setenv/unsetenv calls, dropping the `list` query.
    var envCalls: [[String]] {
      calls.filter { $0.first == "spawn" }
    }
  }

  /// Reports a slice for the platforms it was given and nil otherwise, with no disk access.
  private struct FixedLocator: SliceLocator {
    let paths: [SimPlatform: String]
    func slicePath(for platform: SimPlatform) -> String? {
      paths[platform]
    }
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
  private let tvRuntime = "com.apple.CoreSimulator.SimRuntime.tvOS-18-0"

  // MARK: runtime parsing

  func testRuntimeIdentifierMapsToPlatform() {
    XCTAssertEqual(SimPlatform(runtimeIdentifier: iosRuntime), .ios)
    XCTAssertEqual(SimPlatform(runtimeIdentifier: watchRuntime), .watchos)
    XCTAssertNil(SimPlatform(runtimeIdentifier: tvRuntime))
  }

  func testSliceNamesAreCanonical() {
    XCTAssertEqual(SimPlatform.ios.sliceName, "simble-interpose.dylib")
    XCTAssertEqual(SimPlatform.watchos.sliceName, "simble-interpose-watchos.dylib")
  }

  // MARK: booted-sim parsing

  func testBootedSimulatorsDropsShutdownAndNoSlicePlatforms() {
    let runner = FakeRunner(listJSON: devices([
      (iosRuntime, "IOS-BOOT", "Booted"),
      (iosRuntime, "IOS-OFF", "Shutdown"),
      (watchRuntime, "WATCH-BOOT", "Booted"),
      (tvRuntime, "TV-BOOT", "Booted"),
    ]))
    let arming = SimulatorArming(runner: runner, locator: FixedLocator(paths: [:]))
    let booted = arming.bootedSimulators()
    XCTAssertEqual(Set(booted.map(\.udid)), ["IOS-BOOT", "WATCH-BOOT"])
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: booted.map { ($0.udid, $0.platform) }),
                   ["IOS-BOOT": .ios, "WATCH-BOOT": .watchos])
  }

  // MARK: arm

  func testArmSetsThreeKeysPerPlatformWithMatchingSlice() {
    let runner = FakeRunner(listJSON: devices([
      (iosRuntime, "IOS-BOOT", "Booted"),
      (watchRuntime, "WATCH-BOOT", "Booted"),
    ]))
    let locator = FixedLocator(paths: [.ios: "/s/ios.dylib", .watchos: "/s/watch.dylib"])
    SimulatorArming(runner: runner, locator: locator).armBooted(port: 51234, token: "deadbeef")

    XCTAssertEqual(runner.envCalls.filter { $0.contains("IOS-BOOT") }, [
      ["spawn", "IOS-BOOT", "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", "/s/ios.dylib"],
      ["spawn", "IOS-BOOT", "launchctl", "setenv", "SIMBLE_PORT", "51234"],
      ["spawn", "IOS-BOOT", "launchctl", "setenv", "SIMBLE_TOKEN", "deadbeef"],
    ])
    XCTAssertEqual(runner.envCalls.filter { $0.contains("WATCH-BOOT") }, [
      ["spawn", "WATCH-BOOT", "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", "/s/watch.dylib"],
      ["spawn", "WATCH-BOOT", "launchctl", "setenv", "SIMBLE_PORT", "51234"],
      ["spawn", "WATCH-BOOT", "launchctl", "setenv", "SIMBLE_TOKEN", "deadbeef"],
    ])
  }

  func testArmSkipsBootedSimWithNoBuiltSlice() {
    let runner = FakeRunner(listJSON: devices([
      (iosRuntime, "IOS-BOOT", "Booted"),
      (watchRuntime, "WATCH-BOOT", "Booted"),
    ]))
    // Only the ios slice is built; the booted watch sim must be left alone.
    let locator = FixedLocator(paths: [.ios: "/slices/ios.dylib"])
    SimulatorArming(runner: runner, locator: locator).armBooted(port: 9000, token: "ab")

    XCTAssertTrue(runner.envCalls.contains { $0.contains("IOS-BOOT") })
    XCTAssertFalse(runner.envCalls.contains { $0.contains("WATCH-BOOT") },
                   "a platform with no slice is never armed")
  }

  // MARK: disarm

  func testDisarmUnsetsAllThreeKeysOnEveryBootedSim() {
    let runner = FakeRunner(listJSON: devices([
      (iosRuntime, "IOS-BOOT", "Booted"),
      (watchRuntime, "WATCH-BOOT", "Booted"),
    ]))
    // No slices at all: disarm still clears every booted sim regardless of platform.
    SimulatorArming(runner: runner, locator: FixedLocator(paths: [:])).disarm()

    for udid in ["IOS-BOOT", "WATCH-BOOT"] {
      XCTAssertEqual(runner.envCalls.filter { $0.contains(udid) }, [
        ["spawn", udid, "launchctl", "unsetenv", "DYLD_INSERT_LIBRARIES"],
        ["spawn", udid, "launchctl", "unsetenv", "SIMBLE_PORT"],
        ["spawn", udid, "launchctl", "unsetenv", "SIMBLE_TOKEN"],
      ])
    }
  }
}
