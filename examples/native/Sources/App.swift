// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import SwiftUI

/// An interactive Bluetooth Low Energy console. The Central tab scans, connects, reads, writes,
/// and subscribes; the Peripheral tab publishes a configurable GATT service, advertises, and
/// serves it; the History tab is the unified trail. Results land with haptic and toast feedback.
/// Each call is the real native one; the same actions run unchanged on a device, and in the
/// Simulator armed by the SimBLE helper they reach the host Mac's radio.
///
/// Launch environment (read at startup, all optional):
///   SIMBLE_AUTOSCAN       central starts scanning when it reaches poweredOn.
///   SIMBLE_AUTOADVERTISE  peripheral starts advertising when it reaches poweredOn.
///   SIMBLE_TAB            open on "peripheral" or "history" (default central).
///   SIMBLE_DEMO_SEED      publish, advertise, and bump the counter at launch for screenshots.
@main
struct SimBLEExampleApp: App {
  var body: some Scene {
    WindowGroup { RootView() }
  }
}

struct RootView: View {
  @State private var console = BLEConsole()
  @State private var tab = Self.initialTab

  var body: some View {
    @Bindable var console = console
    TabView(selection: $tab) {
      CentralTab().tag(0)
        .tabItem { Label("Central", systemImage: "antenna.radiowaves.left.and.right") }
      PeripheralTab().tag(1)
        .tabItem { Label("Peripheral", systemImage: "dot.radiowaves.left.and.right") }
      HistoryTab().tag(2)
        .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
    }
    .tint(.blue)
    .environment(console)
    .toast($console.toast)
    .sensoryFeedback(.success, trigger: console.successTick)
    .sensoryFeedback(.error, trigger: console.errorTick)
    .task {
      if ProcessInfo.processInfo.environment["SIMBLE_DEMO_SEED"] == "1" { console.seedDemo() }
    }
  }

  private static var initialTab: Int {
    switch ProcessInfo.processInfo.environment["SIMBLE_TAB"] {
    case "peripheral": 1
    case "history": 2
    default: 0
    }
  }
}

/// Whether launch environment variable `name` is set (present, non-empty).
func launchFlag(_ name: String) -> Bool {
  guard let value = ProcessInfo.processInfo.environment[name] else { return false }
  return !value.isEmpty
}
