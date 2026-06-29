// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import AppKit
import SwiftUI

/// The MenuBarExtra popover: the on/off toggle, the Bluetooth/bridge status, the booted
/// simulators and whether each is armed, and the footer Quit.
@available(macOS 14, *)
struct MenubarView: View {
  @Bindable var model: HelperModel
  @State private var copied = false
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      status
      copyButton
      Divider()
      simulators
      Divider()
      footer
    }
    .frame(width: 300)
  }

  private var header: some View {
    HStack {
      SimBLEWordmark(size: 17)
      Spacer()
      Toggle("", isOn: Binding(get: { model.running }, set: { _ in model.toggle() }))
        .toggleStyle(.switch)
        .labelsHidden()
        .disabled(!model.canToggle)
    }
    .padding(12)
  }

  private var status: some View {
    HStack(spacing: 8) {
      Circle().fill(model.running ? Color.green : Color.secondary).frame(width: 8, height: 8)
      // A plain String, not a LocalizedStringKey, so the port number is not group-formatted.
      Text(verbatim: model.statusLine)
        .font(.callout)
        .foregroundStyle(model.running ? Color.primary : Color.secondary)
      Spacer()
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
  }

  private var copyButton: some View {
    Button {
      if let env = model.schemeEnvironment() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(env, forType: .string)
        withAnimation { copied = true }
      }
    } label: {
      Label(copied ? "Copied" : "Copy scheme environment",
            systemImage: copied ? "checkmark" : "doc.on.clipboard")
        .frame(maxWidth: .infinity)
    }
    .controlSize(.large)
    .disabled(!model.running)
    .padding(.horizontal, 12).padding(.bottom, 10)
    .task(id: copied) {
      if copied {
        try? await Task.sleep(for: .seconds(1.5))
        withAnimation { copied = false }
      }
    }
  }

  private var simulators: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Booted simulators").font(.caption).foregroundStyle(.secondary)
      if model.simulators.isEmpty {
        Text("No booted simulator.")
          .font(.caption).foregroundStyle(.tertiary)
      } else {
        ForEach(model.simulators) { sim in
          HStack(spacing: 10) {
            Image(systemName: sim.platform == "watchOS" ? "applewatch" : "iphone.gen3")
              .foregroundStyle(.tint)
              .frame(width: 22, height: 22)
            Text(verbatim: sim.platform)
              .font(.caption.weight(.medium))
            Spacer()
            Text(sim.armed ? "Armed" : "Not armed")
              .font(.caption2)
              .foregroundStyle(sim.armed ? Color.green : Color.secondary)
          }
        }
      }
    }
    .padding(12)
  }

  private var footer: some View {
    HStack(spacing: 0) {
      Button("Settings…") { openSettings() }
        .frame(maxWidth: .infinity)
      Divider().frame(height: 16)
      Button("Quit") { model.shutdown(); NSApp.terminate(nil) }
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderless)
    .padding(.vertical, 8)
  }
}
