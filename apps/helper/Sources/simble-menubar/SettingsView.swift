// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import SwiftUI

/// The settings window, presented through the native `Settings` scene: a General tab for the
/// pinned port and launch-at-login, and a Status tab for the bridge's live state and version.
@available(macOS 14, *)
struct SettingsView: View {
  @Bindable var model: HelperModel

  var body: some View {
    TabView {
      GeneralSettings(model: model)
        .tabItem { Label("General", systemImage: "gearshape") }
      StatusSettings(model: model)
        .tabItem { Label("Status", systemImage: "info.circle") }
    }
    .frame(width: 440)
  }
}

/// The two things a developer sets: launch at login and a pinned port.
@available(macOS 14, *)
private struct GeneralSettings: View {
  @Bindable var model: HelperModel
  @State private var portText = ""

  var body: some View {
    Form {
      Section {
        Toggle("Launch SimBLE at login", isOn: $model.launchAtLogin)
      }

      Section {
        LabeledContent("Fixed port") {
          HStack(spacing: 8) {
            TextField("Auto", text: $portText)
              .frame(width: 90)
              .multilineTextAlignment(.trailing)
              .onSubmit(applyPort)
            Button("Apply", action: applyPort)
          }
        }
      } footer: {
        Text("Pin a port so the scheme environment stays the same every run. Leave blank for an "
          + "automatic port. Takes effect on the next on/off toggle.")
      }
    }
    .formStyle(.grouped)
    .onAppear { portText = model.fixedPort == 0 ? "" : String(model.fixedPort) }
  }

  private func applyPort() {
    model.fixedPort = Int(portText) ?? 0
    portText = model.fixedPort == 0 ? "" : String(model.fixedPort)
  }
}

/// The bridge's live state, version, and the data directory.
@available(macOS 14, *)
private struct StatusSettings: View {
  @Bindable var model: HelperModel

  var body: some View {
    Form {
      Section {
        LabeledContent("Bridge") {
          // Interpolate the port as a String, not the Int: a Text from a LocalizedStringKey
          // number-groups an integer (it would read "65,176").
          Text(model.running ? "Running on port \(String(model.port))" : "Stopped")
            .foregroundStyle(model.running ? Color.green : Color.secondary)
        }
        if model.running, let started = model.startedAt {
          LabeledContent("Uptime") {
            TimelineView(.periodic(from: started, by: 1)) { context in
              Text(Self.uptime(from: started, to: context.date)).monospacedDigit()
            }
          }
        }
        LabeledContent("Bluetooth", value: model.bluetoothLabel)
        LabeledContent("Simulators", value: model.simulatorSummary)
        LabeledContent("Version", value: model.appVersion)
      }

      Section {
        Button("Open data directory") { model.openDataDirectory() }
      } footer: {
        Text("The port and token live in the data directory, written private to your user.")
      }
    }
    .formStyle(.grouped)
  }

  /// Format elapsed time compactly: "1h 05m", "5m 23s", or "12s".
  private static func uptime(from start: Date, to now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(start)))
    let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
    if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
    if minutes > 0 { return String(format: "%dm %02ds", minutes, seconds) }
    return "\(seconds)s"
  }
}
