// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

// The bridge helper as a menubar app. It runs the same loopback bridge as the CLI
// (SimBLEHelperKit + SimBLEHostCore) behind a SwiftUI MenuBarExtra: an on/off control,
// the bound port and Bluetooth state, and the booted simulators it has armed.
// Constructing the CoreBluetooth managers triggers the macOS Bluetooth prompt because the
// .app carries NSBluetoothAlwaysUsageDescription. It is an accessory app (no dock icon,
// set by LSUIElement in the bundle's Info.plist), signed ad-hoc.

import AppKit
import Foundation
import SwiftUI

/// The process entry point. MenuBarExtra and Observation need macOS 14; an older system
/// exits with a clear message rather than launching a non-functional bar item.
@main
enum Main {
  static func main() {
    guard #available(macOS 14, *) else {
      FileHandle.standardError.write(Data("simble-menubar: requires macOS 14 or newer\n".utf8))
      exit(1)
    }
    SimBLEMenubarApp.main()
  }
}

@available(macOS 14, *)
struct SimBLEMenubarApp: App {
  @State private var model = HelperModel()

  var body: some Scene {
    MenuBarExtra {
      MenubarView(model: model)
    } label: {
      Image(systemName: model.iconName)
    }
    .menuBarExtraStyle(.window)
  }
}
