// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import SwiftUI

/// The SimBLE lockup (mark + wordmark) as a text stand-in, used as the navigation title. A wordmark
/// asset under /assets can replace it.
struct SimBLELockup: View {
  var size: CGFloat = 17

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "antenna.radiowaves.left.and.right")
        .foregroundStyle(.tint)
      Text("SimBLE").font(.system(size: size, weight: .semibold))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("SimBLE")
  }
}

/// The brand navigation header: the Swift badge on the left, the SimBLE lockup as the title, and
/// an About button on the right that presents the About sheet. Applied to every tab for one
/// consistent bar.
private struct BrandHeader: ViewModifier {
  @State private var showAbout = false

  func body(content: Content) -> some View {
    content
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Image(systemName: "swift")
            .foregroundStyle(Color(red: 0.941, green: 0.318, blue: 0.220))
            .accessibilityLabel("Swift")
        }
        ToolbarItem(placement: .principal) { SimBLELockup() }
        ToolbarItem(placement: .topBarTrailing) {
          Button { showAbout = true } label: { Image(systemName: "info.circle") }
            .accessibilityLabel("About SimBLE")
        }
      }
      .sheet(isPresented: $showAbout) { AboutSheet() }
  }
}

extension View {
  /// Adds the SimBLE brand navigation header (Swift badge, lockup, About button).
  func brandHeader() -> some View { modifier(BrandHeader()) }
}

/// The About panel, presented as a sheet from the header: what the project is, that this is the
/// native example, and the Nirapod Labs credit and license.
struct AboutSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            SimBLELockup(size: 26)
            Text("Real Bluetooth Low Energy for the Simulator.")
              .font(.subheadline).foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }

        Section("About") {
          Text("SimBLE injects a small interposer into a simulated app, catches its CoreBluetooth calls, and bridges them to your Mac's radio over an authenticated loopback channel. The app scans, connects, advertises, and serves GATT against real hardware.")
        }

        Section("This example") {
          Text("Native SwiftUI. The Central and Peripheral tabs drive one BLEConsole; a scan, a connect, a write, and a notification all land in the same history.")
        }

        Section {
          LabeledContent("Built by", value: "Nirapod Labs")
          LabeledContent("License", value: "Apache-2.0")
          LabeledContent("Status", value: "Early")
        } footer: {
          Text("© 2026 Nirapod Labs")
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}
