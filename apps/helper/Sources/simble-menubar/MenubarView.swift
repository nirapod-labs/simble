// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import AppKit
import SwiftUI

/// The MenuBarExtra popover: the on/off toggle, the Bluetooth/bridge status, the booted
/// simulators and whether each is armed, and the footer Quit.
@available(macOS 14, *)
struct MenubarView: View {
  @Bindable var model: HelperModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      status
      Divider()
      simulators
      Divider()
      footer
    }
    .frame(width: 300)
  }

  private var header: some View {
    HStack {
      Text(verbatim: "SimBLE").font(.headline)
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

  private var simulators: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Booted simulators").font(.caption).foregroundStyle(.secondary)
      if model.simulators.isEmpty {
        Text("No booted simulator.")
          .font(.caption).foregroundStyle(.tertiary)
      } else {
        ForEach(model.simulators) { sim in
          HStack(spacing: 10) {
            Image(systemName: "iphone.gen3").foregroundStyle(.tint)
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
      Button("Quit") { model.shutdown(); NSApp.terminate(nil) }
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderless)
    .padding(.vertical, 8)
  }
}
