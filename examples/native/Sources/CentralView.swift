// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import SwiftUI

struct CentralView: View {
  /// Start scanning automatically once the central reaches poweredOn.
  let autoScan: Bool

  @State private var central = CentralScanner()

  var body: some View {
    NavigationStack {
      List {
        Section(central.state) {
          Button(central.scanning ? "Stop" : "Scan") { central.toggleScan() }
            .disabled(!central.poweredOn)
        }
        Section("Peripherals") {
          ForEach(central.found) { device in
            Button { central.connect(device) } label: {
              HStack {
                Text(device.name)
                Spacer()
                Text("\(device.rssi) dBm")
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        if !central.log.isEmpty {
          Section("Log") {
            ForEach(central.log) { line in
              Text(line.text)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .navigationTitle("SimBLE Central")
    }
    .onAppear { central.autoScan = autoScan }
  }
}

/// One discovered peripheral, identified for the list.
struct Discovery: Identifiable {
  let id: UUID
  let name: String
  let rssi: Int
  let peripheral: CBPeripheral
}

/// A CoreBluetooth central: scan for any peripheral, list discoveries, and on connect discover
/// services and characteristics and read the first readable characteristic.
@MainActor
@Observable
final class CentralScanner: NSObject, @preconcurrency CBCentralManagerDelegate,
  @preconcurrency CBPeripheralDelegate
{
  private(set) var state = "Starting"
  private(set) var poweredOn = false
  private(set) var scanning = false
  private(set) var found: [Discovery] = []
  private(set) var log: [LogLine] = []

  /// When set, scanning starts on the first poweredOn state.
  var autoScan = false

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
      found.removeAll()
      manager.scanForPeripherals(withServices: nil)
      scanning = true
      append("Scanning")
    }
  }

  /// Connect to a tapped peripheral.
  func connect(_ device: Discovery) {
    manager.stopScan()
    scanning = false
    connected = device.peripheral
    device.peripheral.delegate = self
    manager.connect(device.peripheral)
    append("Connecting to \(device.name)")
  }

  private func append(_ text: String) {
    log.insert(LogLine(text: text), at: 0)
    FileHandle.standardError.write(Data("[simble-example] \(text)\n".utf8))
  }

  // MARK: CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    state = describe(central.state)
    poweredOn = central.state == .poweredOn
    append("State: \(state)")
    if poweredOn, autoScan, !scanning { toggleScan() }
  }

  func centralManager(
    _: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let name = advertisedName ?? peripheral.name ?? "Unknown"
    if let index = found.firstIndex(where: { $0.id == peripheral.identifier }) {
      found[index] = Discovery(
        id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral
      )
    } else {
      found.append(
        Discovery(
          id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral
        )
      )
      append("Found \(name) (\(RSSI) dBm)")
    }
  }

  func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
    append("Connected; discovering services")
    peripheral.discoverServices(nil)
  }

  func centralManager(
    _: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    append(
      "Connect failed for \(peripheral.name ?? "unnamed"): \(error?.localizedDescription ?? "no error")"
    )
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
}
