// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation

/// A simulator platform the helper can arm, each mapping to one interposer slice built against
/// that platform's simulator SDK. The ios and watchos slices are separate files because both are
/// arm64 and cannot share one fat binary. A booted simulator whose platform has no built slice is
/// left alone.
public enum SimPlatform: Equatable, Sendable {
  case ios
  case watchos

  /// The interposer slice file name. The ios slice keeps the canonical name; every other
  /// platform carries a platform-suffixed name.
  public var sliceName: String {
    switch self {
    case .ios: "simble-interpose.dylib"
    case .watchos: "simble-interpose-watchos.dylib"
    }
  }

  /// The dev-checkout build directory `make build` writes this platform's slice into.
  public var devBuildSubpath: String {
    switch self {
    case .ios: "build-sim/bin"
    case .watchos: "build-watchsim/bin"
    }
  }

  /// Map a simctl runtime identifier to a platform with a slice, or nil for one without. The
  /// identifier carries the platform token before the version
  /// (com.apple.CoreSimulator.SimRuntime.iOS-26-5, ...watchOS-11-0).
  public init?(runtimeIdentifier: String) {
    if runtimeIdentifier.contains(".iOS-") {
      self = .ios
    } else if runtimeIdentifier.contains(".watchOS-") {
      self = .watchos
    } else {
      return nil
    }
  }
}

/// The simctl invocation seam. A fake runner can record commands without a real simulator.
public protocol SimctlRunner: Sendable {
  /// Run `xcrun simctl` with `args` and return the exit status and combined output.
  func run(_ args: [String]) -> (status: Int32, output: String)
}

/// Runs `xcrun simctl` as a child process.
public struct ProcessSimctlRunner: SimctlRunner {
  public init() {}

  public func run(_ args: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl"] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
  }
}

/// Locates a platform's interposer slice on disk.
public protocol SliceLocator: Sendable {
  /// The absolute path to `platform`'s slice, or nil when no slice is built for it.
  func slicePath(for platform: SimPlatform) -> String?
}

/// Resolves a slice path from the shipped bundle Resources, then the dev-checkout build tree.
public struct DefaultSliceLocator: SliceLocator {
  private let bundleResourceDirectory: String?
  private let executablePath: String

  /// Build a locator. `bundleResourceDirectory` is the shipped `.app` Resources directory;
  /// `executablePath` is the running binary, the walk-up anchor for the dev build tree.
  public init(
    bundleResourceDirectory: String? = Bundle.main.resourceURL?.path,
    executablePath: String = CommandLine.arguments.first ?? ""
  ) {
    self.bundleResourceDirectory = bundleResourceDirectory
    self.executablePath = executablePath
  }

  public func slicePath(for platform: SimPlatform) -> String? {
    let name = platform.sliceName
    if let resources = bundleResourceDirectory {
      let bundled = URL(fileURLWithPath: resources).appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: bundled.path) { return bundled.path }
    }
    var dir = URL(fileURLWithPath: executablePath)
      .resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0 ..< 10 {
      let candidate = dir.appendingPathComponent("\(platform.devBuildSubpath)/\(name)")
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
      dir = dir.deletingLastPathComponent()
    }
    return nil
  }
}

/// Arms and disarms booted simulators; an app the simulator launches inherits the interposer.
/// Arming sets the slice insert path, the loopback port, and the capability token in the
/// simulator's `launchd` environment; disarming unsets them.
public struct SimulatorArming: Sendable {
  /// The injection environment keys arming sets and disarming unsets.
  static let injectVariable = "DYLD_INSERT_LIBRARIES"
  static let portVariable = "SIMBLE_PORT"
  static let tokenVariable = "SIMBLE_TOKEN"

  private let runner: SimctlRunner
  private let locator: SliceLocator

  /// Build over the simctl seam and the slice locator.
  public init(
    runner: SimctlRunner = ProcessSimctlRunner(),
    locator: SliceLocator = DefaultSliceLocator()
  ) {
    self.runner = runner
    self.locator = locator
  }

  /// Arm every booted simulator whose platform has a built slice. `port` is the loopback
  /// listener's bound port; `token` is the session capability token in hex. Idempotent: a re-arm
  /// writes only a variable that has drifted; safe to call on a timer.
  public func armBooted(port: UInt16, token: String) {
    for sim in bootedSimulators() {
      guard let slice = locator.slicePath(for: sim.platform) else { continue }
      arm(udid: sim.udid, slice: slice, port: port, token: token)
    }
  }

  private func arm(udid: String, slice: String, port: UInt16, token: String) {
    // Set port and token before the insert path. The interposer is inert without both (entry.c);
    // inserting the slice first would yield an injected app that cannot reach the bridge.
    if simulatorEnv(udid, Self.portVariable) != String(port) {
      _ = runner.run(["spawn", udid, "launchctl", "setenv", Self.portVariable, String(port)])
    }
    if simulatorEnv(udid, Self.tokenVariable) != token {
      _ = runner.run(["spawn", udid, "launchctl", "setenv", Self.tokenVariable, token])
    }
    // DYLD_INSERT_LIBRARIES is shared; compose to keep a peer tool's entry (see InjectionEnv).
    let current = simulatorEnv(udid, Self.injectVariable)
    let composed = InjectionEnv.composed(current: current, adding: slice)
    if composed != (current ?? "") {
      _ = runner.run(["spawn", udid, "launchctl", "setenv", Self.injectVariable, composed])
    }
  }

  /// Clear our injection from every booted simulator. Removes only our slice from the shared DYLD
  /// list, never blanket-unsets it; a peer tool's interposer survives. Our own port and token
  /// are ours to unset.
  public func disarm() {
    for sim in bootedSimulators() {
      if let slice = locator.slicePath(for: sim.platform) {
        let current = simulatorEnv(sim.udid, Self.injectVariable)
        let remaining = InjectionEnv.removed(current: current, removing: slice)
        if remaining.isEmpty {
          _ = runner.run(["spawn", sim.udid, "launchctl", "unsetenv", Self.injectVariable])
        } else if remaining != (current ?? "") {
          _ = runner.run(["spawn", sim.udid, "launchctl", "setenv", Self.injectVariable, remaining])
        }
      }
      _ = runner.run(["spawn", sim.udid, "launchctl", "unsetenv", Self.portVariable])
      _ = runner.run(["spawn", sim.udid, "launchctl", "unsetenv", Self.tokenVariable])
    }
  }

  /// Read one variable from a booted simulator's launchd environment, nil when unset.
  private func simulatorEnv(_ udid: String, _ key: String) -> String? {
    let output = runner.run(["spawn", udid, "launchctl", "getenv", key]).output
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Every booted simulator paired with the platform its runtime maps to, parsed from
  /// `simctl list -j devices`. The device map is keyed by runtime identifier.
  public func bootedSimulators() -> [(udid: String, platform: SimPlatform)] {
    let output = runner.run(["list", "-j", "devices"]).output
    guard let data = output.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let devices = root["devices"] as? [String: [[String: Any]]] else { return [] }
    var result: [(udid: String, platform: SimPlatform)] = []
    for (runtimeID, deviceList) in devices {
      guard let platform = SimPlatform(runtimeIdentifier: runtimeID) else { continue }
      for device in deviceList where (device["state"] as? String) == "Booted" {
        guard let udid = device["udid"] as? String else { continue }
        result.append((udid: udid, platform: platform))
      }
    }
    return result
  }
}
