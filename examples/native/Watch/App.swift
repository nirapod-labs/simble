// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import SwiftUI

/// The watchOS example: a CoreBluetooth central that scans, connects to the first peripheral, and
/// reads its first readable characteristic. On an Apple Watch it drives the device radio; in the
/// watchOS Simulator armed by the SimBLE helper, the same calls reach the host Mac's radio.
@main
struct SimBLEWatchApp: App {
  var body: some Scene {
    WindowGroup { ConsoleView() }
  }
}

struct ConsoleView: View {
  @State private var central = CentralConsole()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text(central.state)
          .font(.headline)
        Button(central.scanning ? "Stop" : "Scan") { central.toggleScan() }
          .buttonStyle(.borderedProminent)
        ForEach(central.log) { line in
          Text(line.text)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
    }
  }
}

/// One scrollback line, identified for the list.
struct ConsoleLine: Identifiable {
  let id = UUID()
  let text: String
}

/// A minimal CoreBluetooth central: scan, connect to the first peripheral seen, discover its
/// services and characteristics, and read the first readable characteristic. Every step appends a
/// line to the console.
@MainActor
@Observable
final class CentralConsole: NSObject, @preconcurrency CBCentralManagerDelegate,
  @preconcurrency CBPeripheralDelegate
{
  private(set) var state = "Starting"
  private(set) var scanning = false
  private(set) var log: [ConsoleLine] = []

  private var manager: CBCentralManager!
  private var connected: CBPeripheral?

  override init() {
    super.init()
    manager = CBCentralManager(delegate: self, queue: .main)
  }

  /// Start or stop scanning for any peripheral.
  func toggleScan() {
    if scanning {
      manager.stopScan()
      scanning = false
      append("Stopped scanning")
    } else if manager.state == .poweredOn {
      manager.scanForPeripherals(withServices: nil)
      scanning = true
      append("Scanning")
    }
  }

  private func append(_ text: String) {
    log.insert(ConsoleLine(text: text), at: 0)
  }

  // MARK: CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    state = describe(central.state)
    append("State: \(state)")
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData _: [String: Any],
    rssi RSSI: NSNumber
  ) {
    guard connected == nil else { return }
    append("Found \(peripheral.name ?? "device") (\(RSSI) dBm)")
    central.stopScan()
    scanning = false
    connected = peripheral
    peripheral.delegate = self
    central.connect(peripheral)
  }

  func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
    append("Connected; discovering services")
    peripheral.discoverServices(nil)
  }

  func centralManager(
    _: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error _: Error?
  ) {
    append("Connect failed: \(peripheral.name ?? "device")")
    connected = nil
  }

  // MARK: CBPeripheralDelegate

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices _: Error?) {
    for service in peripheral.services ?? [] {
      peripheral.discoverCharacteristics(nil, for: service)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error _: Error?
  ) {
    for characteristic in service.characteristics ?? []
      where characteristic.properties.contains(.read)
    {
      append("Reading \(characteristic.uuid)")
      peripheral.readValue(for: characteristic)
      return
    }
  }

  func peripheral(
    _: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error _: Error?
  ) {
    let bytes = characteristic.value?.count ?? 0
    append("Read \(bytes) B from \(characteristic.uuid)")
  }

  private func describe(_ state: CBManagerState) -> String {
    switch state {
    case .poweredOn: "Powered on"
    case .poweredOff: "Powered off"
    case .unauthorized: "Unauthorized"
    case .unsupported: "Unsupported"
    case .resetting: "Resetting"
    default: "Unknown"
    }
  }
}
