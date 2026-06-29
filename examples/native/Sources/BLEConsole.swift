// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import Foundation
import Observation
import SwiftUI

/// A transient toast.
struct Toast: Identifiable, Equatable {
  let id = UUID()
  enum Kind { case success, error, info }
  let kind: Kind
  let text: String
}

/// One history line. `ok` is true for a success, false for a failure, nil for a neutral note.
struct LogLine: Identifiable, Equatable {
  let id: Int
  let ok: Bool?
  let text: String
  let time: Date
}

/// One discovered peripheral, identified for the list.
struct Discovery: Identifiable, Equatable {
  let id: UUID
  let name: String
  let rssi: Int
  @ObservationIgnored let peripheral: CBPeripheral

  static func == (lhs: Discovery, rhs: Discovery) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name && lhs.rssi == rhs.rssi
  }
}

/// A human-readable name for a CoreBluetooth manager state.
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

/// Validate a service or characteristic UUID string and return its `CBUUID`, nil when malformed.
/// `CBUUID(string:)` raises on bad input, so the 16-, 32-, and 128-bit forms are checked first.
func parseUUID(_ text: String) -> CBUUID? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  let short = "^[0-9A-F]{4}$"
  let medium = "^[0-9A-F]{8}$"
  let long = "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
  for pattern in [short, medium, long] where trimmed.range(of: pattern, options: .regularExpression) != nil {
    return CBUUID(string: trimmed)
  }
  return nil
}

/// Drives CoreBluetooth on demand from the UI, in both roles, through one model. The central side
/// scans, connects, reads, writes, and subscribes; the peripheral side publishes a configurable
/// GATT service, advertises, and serves reads, writes, and notifications. A unified history trail,
/// a transient toast, and success and failure ticks back the UI. Every call is the real native one;
/// the same actions run unchanged on a device, and in the Simulator armed by the SimBLE helper they
/// reach the host Mac's radio.
@MainActor
@Observable
final class BLEConsole: NSObject {
  private(set) var centralState = "Starting"
  private(set) var peripheralState = "Starting"
  private(set) var centralReady = false
  private(set) var peripheralReady = false
  private(set) var scanning = false
  private(set) var advertising = false
  private(set) var found: [Discovery] = []
  private(set) var connectedName: String?
  private(set) var subscribed = false
  private(set) var counter: UInt8 = 0
  private(set) var subscribers = 0
  private(set) var history: [LogLine] = []
  var toast: Toast?

  /// The published service and characteristic UUIDs, editable on the Peripheral tab. The central
  /// reads, writes, and subscribes the characteristic matching the second.
  var serviceUUIDText = "F000AA00-0451-4000-B000-000000000000"
  var characteristicUUIDText = "F000AA01-0451-4000-B000-000000000000"

  static let localName = "SimBLE Peripheral"

  /// Bumped on every success or failure; a view attaches `.sensoryFeedback` to it.
  private(set) var successTick = 0
  private(set) var errorTick = 0

  @ObservationIgnored private var central: CBCentralManager!
  @ObservationIgnored private var peripheral: CBPeripheralManager!
  @ObservationIgnored private var connected: CBPeripheral?
  @ObservationIgnored private var target: CBCharacteristic?
  @ObservationIgnored private var published: CBMutableCharacteristic?
  @ObservationIgnored private var logSeq = 0

  /// Launch flags the mechanism lane sets to drive the guest headlessly: scan on the central's
  /// first poweredOn, advertise on the peripheral's first poweredOn.
  @ObservationIgnored private let autoScan = launchFlag("SIMBLE_AUTOSCAN")
  @ObservationIgnored private let autoAdvertise = launchFlag("SIMBLE_AUTOADVERTISE")

  /// Whether both UUID fields parse, gating the publish and the GATT-dependent central paths.
  var gattValid: Bool { parseUUID(serviceUUIDText) != nil && parseUUID(characteristicUUIDText) != nil }

  /// Whether a connected peripheral exposes the configured characteristic.
  var hasTarget: Bool { target != nil }

  override init() {
    super.init()
    central = CBCentralManager(delegate: self, queue: .main)
    peripheral = CBPeripheralManager(delegate: self, queue: .main)
  }

  // MARK: central

  /// Start or stop scanning for any peripheral.
  func toggleScan() {
    if scanning {
      central.stopScan()
      scanning = false
      note(nil, "Stopped scanning")
    } else if central.state == .poweredOn {
      found.removeAll()
      central.scanForPeripherals(withServices: nil)
      scanning = true
      note(nil, "Scanning")
    }
  }

  /// Connect to a tapped peripheral and discover the configured service.
  func connect(_ device: Discovery) {
    central.stopScan()
    scanning = false
    connected = device.peripheral
    connectedName = device.name
    subscribed = false
    target = nil
    device.peripheral.delegate = self
    central.connect(device.peripheral)
    note(nil, "Connecting to \(device.name)")
  }

  /// Write one byte to the configured characteristic with response.
  func write(_ value: UInt8) {
    guard let connected, let target else { return }
    connected.writeValue(Data([value]), for: target, type: .withResponse)
    note(nil, "Writing \(value)")
  }

  /// Subscribe to or unsubscribe from the configured characteristic's notifications.
  func toggleSubscribe() {
    guard let connected, let target else { return }
    connected.setNotifyValue(!subscribed, for: target)
  }

  // MARK: peripheral

  /// Start or stop advertising the published service.
  func toggleAdvertise() {
    guard let serviceUUID = parseUUID(serviceUUIDText) else {
      return toast(.error, "Service UUID is malformed")
    }
    if advertising {
      peripheral.stopAdvertising()
      advertising = false
      note(nil, "Stopped advertising")
    } else if peripheral.state == .poweredOn {
      peripheral.startAdvertising([
        CBAdvertisementDataLocalNameKey: Self.localName,
        CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
      ])
      note(nil, "Advertising as \(Self.localName)")
    }
  }

  /// Bump the served counter and push it to subscribed centrals.
  func incrementAndNotify() {
    guard let published else { return }
    counter &+= 1
    let delivered = peripheral.updateValue(Data([counter]), for: published, onSubscribedCentrals: nil)
    note(delivered ? true : nil, "Notified counter \(counter)")
  }

  /// Republish the service from the current UUID fields. Removes the prior service first, so a
  /// relaunch or an edit never leaves a duplicate primary in the GATT.
  func republishService() {
    guard peripheral.state == .poweredOn else { return }
    guard let serviceUUID = parseUUID(serviceUUIDText),
          let characteristicUUID = parseUUID(characteristicUUIDText)
    else {
      return toast(.error, "GATT UUIDs are malformed")
    }
    peripheral.removeAllServices()
    let characteristic = CBMutableCharacteristic(
      type: characteristicUUID,
      properties: [.read, .write, .notify],
      value: nil,
      permissions: [.readable, .writeable])
    let service = CBMutableService(type: serviceUUID, primary: true)
    service.characteristics = [characteristic]
    published = characteristic
    peripheral.add(service)
  }

  // MARK: history

  func clearHistory() { history.removeAll() }

  /// Screenshot-only seed, gated behind SIMBLE_DEMO_SEED at launch. Publishes the service,
  /// advertises, and bumps the counter twice; the populated screens can then be captured headlessly.
  /// Every line is a real local call, not a faked discovery.
  func seedDemo() {
    republishService()
    toggleAdvertise()
    incrementAndNotify()
    incrementAndNotify()
  }

  // MARK: internals

  private func note(_ ok: Bool?, _ text: String) {
    logSeq += 1
    history.insert(LogLine(id: logSeq, ok: ok, text: text, time: Date()), at: 0)
    if ok == true { successTick += 1 } else if ok == false { errorTick += 1 }
    FileHandle.standardError.write(Data("[simble-example] \(text)\n".utf8))
  }

  private func toast(_ kind: Toast.Kind, _ text: String) {
    toast = Toast(kind: kind, text: text)
  }
}

// MARK: CBCentralManagerDelegate

extension BLEConsole: @preconcurrency CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    centralState = describe(central.state)
    centralReady = central.state == .poweredOn
    note(nil, "Central: \(centralState)")
    if centralReady, autoScan, !scanning { toggleScan() }
  }

  func centralManager(
    _: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
      ?? peripheral.name ?? "Unknown"
    let entry = Discovery(id: peripheral.identifier, name: name, rssi: RSSI.intValue,
                          peripheral: peripheral)
    if let index = found.firstIndex(where: { $0.id == peripheral.identifier }) {
      found[index] = entry
    } else {
      found.append(entry)
      note(nil, "Found \(name) (\(RSSI) dBm)")
    }
  }

  func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
    note(true, "Connected; discovering services")
    peripheral.discoverServices(parseUUID(serviceUUIDText).map { [$0] })
  }

  func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    note(false, "Connect failed: \(error?.localizedDescription ?? "no error")")
    connected = nil
    connectedName = nil
  }

  func centralManager(
    _: CBCentralManager,
    didDisconnectPeripheral _: CBPeripheral,
    error: Error?
  ) {
    note(error == nil, "Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
    connected = nil
    connectedName = nil
    target = nil
    subscribed = false
  }
}

// MARK: CBPeripheralDelegate

extension BLEConsole: @preconcurrency CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices _: Error?) {
    let characteristicUUID = parseUUID(characteristicUUIDText)
    for service in peripheral.services ?? [] {
      peripheral.discoverCharacteristics(characteristicUUID.map { [$0] }, for: service)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error _: Error?
  ) {
    let characteristicUUID = parseUUID(characteristicUUIDText)
    guard let match = (service.characteristics ?? []).first(where: {
      characteristicUUID == nil || $0.uuid == characteristicUUID
    }) else { return }
    target = match
    note(true, "Found characteristic \(match.uuid)")
    if match.properties.contains(.read) { peripheral.readValue(for: match) }
  }

  func peripheral(
    _: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error { return note(false, "Read failed: \(error.localizedDescription)") }
    let bytes = characteristic.value?.count ?? 0
    note(true, "Value \(bytes) B from \(characteristic.uuid)")
  }

  func peripheral(
    _: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    note(error == nil, error.map { "Write failed: \($0.localizedDescription)" }
      ?? "Wrote \(characteristic.uuid)")
  }

  func peripheral(
    _: CBPeripheral,
    didUpdateNotificationStateFor _: CBCharacteristic,
    error: Error?
  ) {
    if let error { return note(false, "Subscribe failed: \(error.localizedDescription)") }
    subscribed.toggle()
    note(true, subscribed ? "Subscribed" : "Unsubscribed")
  }
}

// MARK: CBPeripheralManagerDelegate

extension BLEConsole: @preconcurrency CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    peripheralState = describe(peripheral.state)
    peripheralReady = peripheral.state == .poweredOn
    note(nil, "Peripheral: \(peripheralState)")
    if peripheral.state == .poweredOn {
      if published == nil { republishService() }
      if autoAdvertise, !advertising { toggleAdvertise() }
    }
  }

  func peripheralManager(_: CBPeripheralManager, didAdd _: CBService, error: Error?) {
    note(error == nil, error.map { "Add service failed: \($0.localizedDescription)" }
      ?? "Service published")
  }

  func peripheralManagerDidStartAdvertising(_: CBPeripheralManager, error: Error?) {
    if let error { return note(false, "Advertise failed: \(error.localizedDescription)") }
    advertising = true
    note(true, "Advertising")
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    request.value = Data([counter])
    peripheral.respond(to: request, withResult: .success)
    note(true, "Served read")
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    for request in requests where request.value?.first != nil {
      counter = request.value!.first!
    }
    if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    note(true, "Served write counter \(counter)")
  }

  func peripheralManager(
    _: CBPeripheralManager,
    central _: CBCentral,
    didSubscribeTo _: CBCharacteristic
  ) {
    subscribers += 1
    note(true, "Central subscribed")
  }

  func peripheralManager(
    _: CBPeripheralManager,
    central _: CBCentral,
    didUnsubscribeFrom _: CBCharacteristic
  ) {
    subscribers = max(0, subscribers - 1)
    note(nil, "Central unsubscribed")
  }
}
