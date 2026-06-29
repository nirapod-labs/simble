// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import SwiftUI

/// The iOS example: one app with a Central tab and a Peripheral tab. The Central tab scans, lists
/// peripherals, connects, and reads a characteristic; the Peripheral tab publishes a service,
/// advertises, and serves reads, writes, and notifications. In the iOS Simulator armed by the SimBLE
/// helper, both reach the host Mac's radio; on a device they drive the device radio.
///
/// Launch environment (read at startup, all optional):
///   SIMBLE_AUTOSCAN       central starts scanning when it reaches poweredOn.
///   SIMBLE_AUTOADVERTISE  peripheral starts advertising when it reaches poweredOn.
///   SIMBLE_TAB=peripheral open on the Peripheral tab (default Central).
@main
struct SimBLEExampleApp: App {
  @State private var selection: Role = launchTab()

  var body: some Scene {
    WindowGroup {
      TabView(selection: $selection) {
        CentralView(autoScan: launchFlag("SIMBLE_AUTOSCAN"))
          .tabItem { Label("Central", systemImage: "antenna.radiowaves.left.and.right") }
          .tag(Role.central)
        PeripheralView(autoAdvertise: launchFlag("SIMBLE_AUTOADVERTISE"))
          .tabItem { Label("Peripheral", systemImage: "dot.radiowaves.left.and.right") }
          .tag(Role.peripheral)
      }
    }
  }
}

/// Which role tab is shown.
enum Role {
  case central
  case peripheral
}

/// The tab to open from SIMBLE_TAB; central unless it is "peripheral".
func launchTab() -> Role {
  ProcessInfo.processInfo.environment["SIMBLE_TAB"] == "peripheral" ? .peripheral : .central
}

/// Whether launch environment variable `name` is set (present, non-empty).
func launchFlag(_ name: String) -> Bool {
  guard let value = ProcessInfo.processInfo.environment[name] else { return false }
  return !value.isEmpty
}

/// One log line, identified for a list. Shared by both roles.
struct LogLine: Identifiable {
  let id = UUID()
  let text: String
}

/// A human-readable name for a CoreBluetooth manager state. Shared by both roles.
func describe(_ state: CBManagerState) -> String {
  switch state {
  case .poweredOn: "Powered on"
  case .poweredOff: "Powered off"
  case .unauthorized: "Unauthorized"
  case .unsupported: "Unsupported"
  case .resetting: "Resetting"
  default: "Unknown"
  }
}
