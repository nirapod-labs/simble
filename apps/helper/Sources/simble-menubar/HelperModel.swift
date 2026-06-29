// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import AppKit
import Foundation
import Observation
import ServiceManagement
import SimBLEHelperKit
import SimBLEHostCore
import SimBLEProtocol

/// The Bluetooth radio state the menubar reads, mapped from the central manager's raw
/// `CBManagerState`. Only `poweredOn` lets the bridge serve.
enum BluetoothState: Equatable {
  case unknown
  case unsupported
  case unauthorized
  case poweredOff
  case poweredOn

  /// Map a raw `CBManagerState` to the menubar state; unmatched values read as unknown.
  init(rawManagerState: UInt64) {
    switch rawManagerState {
    case 2: self = .unsupported
    case 3: self = .unauthorized
    case 4: self = .poweredOff
    case Wire.managerStatePoweredOn: self = .poweredOn
    default: self = .unknown
    }
  }
}

/// A booted simulator and whether the bridge has armed it this session.
struct ArmedSimulator: Identifiable {
  let id: String
  let platform: String
  var armed: Bool
}

/// The menubar's whole state and the bridge lifecycle behind it: the on/off control, the
/// Bluetooth state, the bound port, and the armed simulators. The view binds to this; it owns
/// the CoreBluetooth managers, the `LoopbackListener`, and the `SimulatorArming` driver.
@available(macOS 14, *)
@MainActor
@Observable
final class HelperModel {
  private(set) var bluetooth: BluetoothState = .unknown
  private(set) var running = false
  private(set) var port: UInt16 = 0
  private(set) var simulators: [ArmedSimulator] = []

  /// A pinned listener port, 0 for an automatic one. Editable in Settings; takes effect on the
  /// next bridge start.
  var fixedPort: Int = 0
  /// When the bridge last started, for the Settings uptime readout.
  private(set) var startedAt: Date?
  /// Whether the helper is a macOS login item.
  var launchAtLogin: Bool = false {
    didSet { applyLaunchAtLogin() }
  }

  private let central = CoreBluetoothCentral()
  private let peripheral = CoreBluetoothPeripheral()
  private let arming = SimulatorArming()
  private var listener: LoopbackListener?
  private var token: CapabilityToken?
  private var stateTimer: Timer?
  private var rearmTick = 0

  init() {
    // A property set inside init does not fire its didSet, so reading the current login-item
    // status here never re-registers it.
    launchAtLogin = SMAppService.mainApp.status == .enabled
    // Constructing the managers above starts the CoreBluetooth stack, which triggers the
    // macOS Bluetooth prompt on first run. Poll the central state off the main run loop so
    // the menubar stays responsive while the radio reaches poweredOn; arm once it does.
    refreshState()
    stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshState() }
    }
  }

  /// The status-bar glyph: the bridge mark when serving, a slashed mark when off, and a
  /// warning triangle when Bluetooth is unavailable.
  var iconName: String {
    guard bluetooth == .poweredOn else { return "exclamationmark.triangle" }
    return running ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
  }

  /// A one-line Bluetooth/bridge status for the menubar, built as a plain String so a port
  /// number is never number-grouped by a `LocalizedStringKey`.
  var statusLine: String {
    switch bluetooth {
    case .poweredOn:
      running ? "Bridge running on port " + String(port) : "Bluetooth ready"
    case .unauthorized:
      "Bluetooth not authorized"
    case .unsupported:
      "Bluetooth Low Energy not supported"
    case .poweredOff:
      "Bluetooth is off"
    case .unknown:
      "Starting Bluetooth"
    }
  }

  /// A short Bluetooth-state label for the Settings status tab.
  var bluetoothLabel: String {
    switch bluetooth {
    case .poweredOn: "Ready"
    case .unauthorized: "Not authorized"
    case .unsupported: "Unsupported"
    case .poweredOff: "Off"
    case .unknown: "Starting"
    }
  }

  /// A count of booted simulators and how many the bridge has armed.
  var simulatorSummary: String {
    if simulators.isEmpty { return "None booted" }
    let armed = simulators.filter(\.armed).count
    return "\(simulators.count) booted, \(armed) armed"
  }

  /// Whether the on/off control can act: only once the radio is authorized and on.
  var canToggle: Bool {
    bluetooth == .poweredOn
  }

  func toggle() {
    if running {
      stop()
    } else {
      start()
    }
  }

  /// Read the central state and, once poweredOn, bring the bridge up. Refresh the armed
  /// simulators while running so a sim booted after arming shows as not-yet-armed.
  private func refreshState() {
    bluetooth = BluetoothState(rawManagerState: central.managerState())
    if bluetooth == .poweredOn, !running {
      start()
    }
    if running {
      refreshSimulators()
      rearm()
    }
  }

  /// Re-arm booted simulators about every two seconds (every fourth 0.5s poll); a sim booted,
  /// rebooted, or clobbered after bridge start recovers without a manual toggle. Idempotent; runs
  /// off the main actor to keep the menubar responsive during the simctl spawns.
  private func rearm() {
    rearmTick += 1
    guard rearmTick >= 4, let token else { return }
    rearmTick = 0
    let arming = self.arming
    let port = self.port
    let hex = token.hex
    Task.detached { arming.armBooted(port: port, token: hex) }
  }

  /// Mint a token, start the loopback listener, arm the booted simulators, and write the
  /// discovery record. Mirrors the CLI bring-up; a no-op unless the radio is poweredOn and
  /// the bridge is not already running.
  func start() {
    guard bluetooth == .poweredOn, !running else { return }
    let token = CapabilityToken()
    let listener = LoopbackListener(
      router: RequestRouter(
        service: CentralService(backend: central, peripheralSupported: true),
        peripheralService: PeripheralService(backend: peripheral),
        gate: AuthGate(session: token)
      )
    )
    do {
      let pinned = fixedPort != 0 ? UInt16(exactly: fixedPort) : nil
      let requested = pinned
        ?? ProcessInfo.processInfo.environment["SIMBLE_PORT"].flatMap { UInt16($0) } ?? 0
      try listener.start(port: requested)
    } catch {
      return
    }
    self.token = token
    self.listener = listener
    port = listener.port
    running = true
    startedAt = Date()
    arming.armBooted(port: listener.port, token: token.hex)
    try? HelperState.write(port: listener.port, token: token.hex)
    refreshSimulators()
  }

  /// Disarm the simulators, remove the discovery record, and stop the listener.
  func stop() {
    arming.disarm()
    HelperState.remove()
    listener?.stop()
    listener = nil
    token = nil
    running = false
    port = 0
    startedAt = nil
    refreshSimulators()
  }

  /// Tear down on quit so a later app never injects against a dead bridge.
  func shutdown() {
    if running { stop() }
    stateTimer?.invalidate()
    stateTimer = nil
  }

  /// Refresh the booted-simulator list. A simulator counts as armed when the bridge is
  /// running and a slice is built for its platform.
  private func refreshSimulators() {
    let armable = running
    simulators = arming.bootedSimulators().map { sim in
      ArmedSimulator(id: sim.udid, platform: sim.platform.label, armed: armable)
    }
  }

  /// The bundle's marketing version, "dev" outside a built `.app`.
  var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
  }

  /// The debug-scheme environment for manual injection, nil when the bridge is off or no iOS
  /// slice is built. The arming driver owns the composition and the injection keys.
  func schemeEnvironment() -> String? {
    guard running, let token else { return nil }
    return arming.schemeEnvironment(port: port, token: token.hex)
  }

  /// Reveal the helper's data directory in Finder.
  func openDataDirectory() {
    guard let url = try? HelperState.directory() else { return }
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
  }

  /// Register or unregister the helper as a login item.
  private func applyLaunchAtLogin() {
    do {
      if launchAtLogin { try SMAppService.mainApp.register() }
      else { try SMAppService.mainApp.unregister() }
    } catch {
      // A `swift run` outside a registered `.app` cannot set a login item.
    }
  }
}

private extension SimPlatform {
  /// A short human label for the menubar row.
  var label: String {
    switch self {
    case .ios: "iOS"
    case .watchos: "watchOS"
    }
  }
}
