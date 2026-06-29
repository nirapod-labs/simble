// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import SwiftUI

struct PeripheralView: View {
  /// Start advertising automatically once the peripheral reaches poweredOn.
  let autoAdvertise: Bool

  @State private var server = PeripheralServer()

  var body: some View {
    NavigationStack {
      List {
        Section(server.state) {
          Button(server.advertising ? "Stop advertising" : "Advertise") { server.toggleAdvertise() }
            .disabled(!server.poweredOn)
        }
        Section("Value") {
          LabeledContent("Counter", value: "\(server.counter)")
          Button("Increment and notify") { server.increment() }
            .disabled(server.subscribers == 0)
        }
        Section("Status") {
          LabeledContent("Subscribers", value: "\(server.subscribers)")
        }
        if !server.log.isEmpty {
          Section("Log") {
            ForEach(server.log) { line in
              Text(line.text)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .navigationTitle("SimBLE Peripheral")
    }
    .onAppear { server.autoAdvertise = autoAdvertise }
  }
}

/// A CoreBluetooth peripheral: publish one service with one readable and notifiable characteristic,
/// advertise a local name, serve reads with the current counter, and accept writes.
@MainActor
@Observable
final class PeripheralServer: NSObject, @preconcurrency CBPeripheralManagerDelegate {
  static let serviceUUID = CBUUID(string: "F000AA00-0451-4000-B000-000000000000")
  static let characteristicUUID = CBUUID(string: "F000AA01-0451-4000-B000-000000000000")
  static let localName = "SimBLE Peripheral"

  private(set) var state = "Starting"
  private(set) var poweredOn = false
  private(set) var advertising = false
  private(set) var counter: UInt8 = 0
  private(set) var subscribers = 0
  private(set) var log: [LogLine] = []

  /// When set, advertising starts on the first poweredOn state.
  var autoAdvertise = false

  private var manager: CBPeripheralManager!
  private var characteristic: CBMutableCharacteristic!

  override init() {
    super.init()
    manager = CBPeripheralManager(delegate: self, queue: .main)
  }

  /// Start or stop advertising the service.
  func toggleAdvertise() {
    if advertising {
      manager.stopAdvertising()
      advertising = false
      append("Stopped advertising")
    } else if manager.state == .poweredOn {
      manager.startAdvertising([
        CBAdvertisementDataLocalNameKey: Self.localName,
        CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
      ])
      append("Advertising as \(Self.localName)")
    }
  }

  /// Bump the counter and push the new value to subscribers.
  func increment() {
    counter &+= 1
    let value = Data([counter])
    manager.updateValue(value, for: characteristic, onSubscribedCentrals: nil)
    append("Notified counter \(counter)")
  }

  private func publishService() {
    characteristic = CBMutableCharacteristic(
      type: Self.characteristicUUID,
      properties: [.read, .notify],
      value: nil,
      permissions: [.readable])
    let service = CBMutableService(type: Self.serviceUUID, primary: true)
    service.characteristics = [characteristic]
    manager.add(service)
  }

  private func append(_ text: String) {
    log.insert(LogLine(text: text), at: 0)
    FileHandle.standardError.write(Data("[simble-example] \(text)\n".utf8))
  }

  // MARK: CBPeripheralManagerDelegate

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    state = describe(peripheral.state)
    poweredOn = peripheral.state == .poweredOn
    append("State: \(state)")
    if peripheral.state == .poweredOn {
      publishService()
      if autoAdvertise, !advertising { toggleAdvertise() }
    }
  }

  func peripheralManager(
    _: CBPeripheralManager,
    didAdd _: CBService,
    error: Error?
  ) {
    if let error { append("Add service failed: \(error.localizedDescription)") }
    else { append("Service published") }
  }

  func peripheralManagerDidStartAdvertising(_: CBPeripheralManager, error: Error?) {
    if let error { append("Advertise failed: \(error.localizedDescription)") }
    else { advertising = true }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didReceiveRead request: CBATTRequest
  ) {
    request.value = Data([counter])
    peripheral.respond(to: request, withResult: .success)
    append("Served read")
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didReceiveWrite requests: [CBATTRequest]
  ) {
    for request in requests {
      if let byte = request.value?.first { counter = byte }
    }
    if let first = requests.first {
      peripheral.respond(to: first, withResult: .success)
    }
    append("Served write counter \(counter)")
  }

  func peripheralManager(
    _: CBPeripheralManager,
    central _: CBCentral,
    didSubscribeTo _: CBCharacteristic
  ) {
    subscribers += 1
    append("Central subscribed")
  }

  func peripheralManager(
    _: CBPeripheralManager,
    central _: CBCentral,
    didUnsubscribeFrom _: CBCharacteristic
  ) {
    subscribers = max(0, subscribers - 1)
    append("Central unsubscribed")
  }
}
