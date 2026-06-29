// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHelperKit
import XCTest

/// The arming logic with a fake simctl runner that models each simulator's launchd environment,
/// and a fixed slice locator: composing the shared insert list to keep a peer tool's slice,
/// idempotent re-arm, and a teardown that removes only our own slice. No real simulator runs here.
final class SimulatorArmingTests: XCTestCase {
  /// Records every simctl call and models each sim's launchd env; getenv reads back what setenv
  /// wrote, and end state shows the compose/teardown result.
  private final class FakeRunner: SimctlRunner, @unchecked Sendable {
    let listJSON: String
    private(set) var calls: [[String]] = []
    private var env: [String: [String: String]] = [:]

    init(listJSON: String) { self.listJSON = listJSON }

    func run(_ args: [String]) -> (status: Int32, output: String) {
      calls.append(args)
      if args.first == "list" { return (0, listJSON) }
      guard args.count >= 5, args[0] == "spawn", args[2] == "launchctl" else { return (0, "") }
      let udid = args[1], verb = args[3], key = args[4]
      switch verb {
      case "getenv": return (0, env[udid]?[key] ?? "")
      case "setenv": if args.count > 5 { env[udid, default: [:]][key] = args[5] }
      case "unsetenv": env[udid]?[key] = nil
      default: break
      }
      return (0, "")
    }

    func value(_ udid: String, _ key: String) -> String? { env[udid]?[key] }
    func seed(_ udid: String, _ key: String, _ value: String) { env[udid, default: [:]][key] = value }
    var setenvCount: Int { calls.filter { $0.count >= 4 && $0[0] == "spawn" && $0[3] == "setenv" }.count }
  }

  private struct FixedLocator: SliceLocator {
    let paths: [SimPlatform: String]
    func slicePath(for platform: SimPlatform) -> String? { paths[platform] }
  }

  private func devices(_ entries: [(runtime: String, udid: String, state: String)]) -> String {
    var byRuntime: [String: [[String: String]]] = [:]
    for entry in entries {
      byRuntime[entry.runtime, default: []].append(["udid": entry.udid, "state": entry.state])
    }
    return String(data: try! JSONSerialization.data(withJSONObject: ["devices": byRuntime]), encoding: .utf8)!
  }

  private let iosRuntime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
  private let watchRuntime = "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"
  private let tvRuntime = "com.apple.CoreSimulator.SimRuntime.tvOS-18-0"
  private let iosSlice = "/slices/simble-interpose.dylib"
  private let peerSlice = "/slices/simenclave-interpose.dylib"

  private func oneIOS(_ udid: String = "IOS-BOOT") -> FakeRunner {
    FakeRunner(listJSON: devices([(iosRuntime, udid, "Booted")]))
  }

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
    let booted = SimulatorArming(runner: runner, locator: FixedLocator(paths: [:])).bootedSimulators()
    XCTAssertEqual(Set(booted.map(\.udid)), ["IOS-BOOT", "WATCH-BOOT"])
  }

  // MARK: arm

  func testArmSetsAllThreeKeysWithMatchingSlice() {
    let runner = FakeRunner(listJSON: devices([
      (iosRuntime, "IOS-BOOT", "Booted"),
      (watchRuntime, "WATCH-BOOT", "Booted"),
    ]))
    let locator = FixedLocator(paths: [.ios: "/s/ios.dylib", .watchos: "/s/watch.dylib"])
    SimulatorArming(runner: runner, locator: locator).armBooted(port: 51234, token: "deadbeef")

    XCTAssertEqual(runner.value("IOS-BOOT", "DYLD_INSERT_LIBRARIES"), "/s/ios.dylib")
    XCTAssertEqual(runner.value("IOS-BOOT", "SIMBLE_PORT"), "51234")
    XCTAssertEqual(runner.value("IOS-BOOT", "SIMBLE_TOKEN"), "deadbeef")
    XCTAssertEqual(runner.value("WATCH-BOOT", "DYLD_INSERT_LIBRARIES"), "/s/watch.dylib")
  }

  func testArmSkipsBootedSimWithNoBuiltSlice() {
    let runner = FakeRunner(listJSON: devices([
      (iosRuntime, "IOS-BOOT", "Booted"),
      (watchRuntime, "WATCH-BOOT", "Booted"),
    ]))
    SimulatorArming(runner: runner, locator: FixedLocator(paths: [.ios: iosSlice]))
      .armBooted(port: 9000, token: "ab")
    XCTAssertNotNil(runner.value("IOS-BOOT", "DYLD_INSERT_LIBRARIES"))
    XCTAssertNil(runner.value("WATCH-BOOT", "DYLD_INSERT_LIBRARIES"),
                 "a platform with no slice is never armed")
  }

  func testArmPreservesAPeerToolsSlice() {
    // The coexistence case: a peer (SimEnclave) armed first; our arm must keep its entry.
    let runner = oneIOS()
    runner.seed("IOS-BOOT", "DYLD_INSERT_LIBRARIES", peerSlice)
    SimulatorArming(runner: runner, locator: FixedLocator(paths: [.ios: iosSlice]))
      .armBooted(port: 7000, token: "tok")
    XCTAssertEqual(runner.value("IOS-BOOT", "DYLD_INSERT_LIBRARIES"), "\(peerSlice):\(iosSlice)")
  }

  func testReArmIsIdempotent() {
    let runner = oneIOS()
    let arming = SimulatorArming(runner: runner, locator: FixedLocator(paths: [.ios: iosSlice]))
    arming.armBooted(port: 7000, token: "tok")
    let afterFirst = runner.setenvCount
    arming.armBooted(port: 7000, token: "tok")
    XCTAssertEqual(runner.value("IOS-BOOT", "DYLD_INSERT_LIBRARIES"), iosSlice, "no duplicate slice")
    XCTAssertEqual(runner.setenvCount, afterFirst, "a steady-state re-arm writes nothing")
  }

  // MARK: disarm

  func testDisarmRemovesOnlyOurSlice() {
    let runner = oneIOS()
    runner.seed("IOS-BOOT", "DYLD_INSERT_LIBRARIES", peerSlice)
    let arming = SimulatorArming(runner: runner, locator: FixedLocator(paths: [.ios: iosSlice]))
    arming.armBooted(port: 7000, token: "tok")
    arming.disarm()
    XCTAssertEqual(runner.value("IOS-BOOT", "DYLD_INSERT_LIBRARIES"), peerSlice, "peer slice survives")
    XCTAssertNil(runner.value("IOS-BOOT", "SIMBLE_PORT"))
    XCTAssertNil(runner.value("IOS-BOOT", "SIMBLE_TOKEN"))
  }

  func testDisarmUnsetsInsertVarWhenOurSliceWasTheOnlyEntry() {
    let runner = oneIOS()
    let arming = SimulatorArming(runner: runner, locator: FixedLocator(paths: [.ios: iosSlice]))
    arming.armBooted(port: 7000, token: "tok")
    arming.disarm()
    XCTAssertNil(runner.value("IOS-BOOT", "DYLD_INSERT_LIBRARIES"))
  }
}
