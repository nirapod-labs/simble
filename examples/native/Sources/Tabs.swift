// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import SwiftUI

/// Scan, connect, then read, write, and subscribe the configured characteristic on the connection.
struct CentralTab: View {
  @Environment(BLEConsole.self) private var console
  @State private var writeValue = 0

  var body: some View {
    NavigationStack {
      List {
        Section(console.centralState) {
          Button(console.scanning ? "Stop" : "Scan") { console.toggleScan() }
            .disabled(!console.centralReady)
        }

        Section("Peripherals") {
          if console.found.isEmpty {
            Text("No peripherals yet. Start a scan.").foregroundStyle(.secondary)
          } else {
            ForEach(console.found) { device in
              Button { console.connect(device) } label: { DiscoveryRow(device: device) }
                .buttonStyle(.plain)
            }
          }
        }

        if let name = console.connectedName {
          Section {
            LabeledContent("Connected", value: name)
            Stepper("Write byte \(writeValue)", value: $writeValue, in: 0 ... 255)
            Button {
              console.write(UInt8(writeValue))
            } label: {
              Label("Write to characteristic", systemImage: "square.and.pencil")
            }
            .disabled(!console.hasTarget)
            Button {
              console.toggleSubscribe()
            } label: {
              Label(console.subscribed ? "Unsubscribe" : "Subscribe",
                    systemImage: console.subscribed ? "bell.slash" : "bell")
            }
            .disabled(!console.hasTarget)
          } header: {
            Text("Connection")
          } footer: {
            Text(console.hasTarget
              ? "Reads land in History; a write echoes back, and a subscription streams the peripheral's counter."
              : "Discovering the configured characteristic.")
          }
        }
      }
      .brandHeader()
    }
  }
}

/// Publish a configurable GATT service, advertise it, and serve reads, writes, and notifications.
struct PeripheralTab: View {
  @Environment(BLEConsole.self) private var console
  @FocusState private var editing: Bool

  var body: some View {
    @Bindable var console = console
    NavigationStack {
      List {
        Section(console.peripheralState) {
          Button(console.advertising ? "Stop advertising" : "Advertise") { console.toggleAdvertise() }
            .disabled(!console.peripheralReady)
        }

        Section {
          TextField("Service UUID", text: $console.serviceUUIDText)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(.system(.footnote, design: .monospaced))
            .focused($editing)
          TextField("Characteristic UUID", text: $console.characteristicUUIDText)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(.system(.footnote, design: .monospaced))
            .focused($editing)
          Button {
            editing = false
            console.republishService()
          } label: {
            Label("Republish service", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(!console.gattValid)
        } header: {
          Text("GATT")
        } footer: {
          Text(console.gattValid
            ? "16-, 32-, or 128-bit UUIDs. Republishing removes the prior service first."
            : "A UUID is malformed. Use a 16-, 32-, or 128-bit form.")
        }

        Section("Value") {
          LabeledContent("Counter", value: "\(console.counter)")
          Button("Increment and notify") { console.incrementAndNotify() }
            .disabled(!console.peripheralReady)
        }

        Section("Status") {
          LabeledContent("Subscribers", value: "\(console.subscribers)")
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .brandHeader()
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") { editing = false }
        }
      }
    }
  }
}

/// The full trail of operations, newest first, as a plain grouped list.
struct HistoryTab: View {
  @Environment(BLEConsole.self) private var console

  var body: some View {
    NavigationStack {
      List {
        if console.history.isEmpty {
          ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath",
                                 description: Text("Run an operation and it shows up here."))
        } else {
          ForEach(console.history) { line in HistoryRow(line: line) }
        }
      }
      .brandHeader()
      .toolbar {
        if !console.history.isEmpty {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Clear", role: .destructive) {
              withAnimation(.snappy) { console.clearHistory() }
            }
          }
        }
      }
    }
  }
}
