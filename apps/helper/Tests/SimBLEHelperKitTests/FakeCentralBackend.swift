// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLEHostCore
import SimBLEProtocol

/// A radio-free `CentralBackend` for the helper round-trip tests. It returns canned
/// results and exposes the event sink, so a loopback client drives a full
/// request-response and reads a streamed event without Bluetooth.
final class FakeCentralBackend: CentralBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var sink: (@Sendable (CentralBackendEvent) -> Void)?

  var state: UInt64 = Wire.managerStatePoweredOn
  var services: [String] = ["180D"]
  var characteristics: [String] = ["2A37"]
  var readValue = Data([0x48, 0x49])
  var notifyResult = true
  var rssiValue: Int64 = -55
  var peripheralStateValue: UInt64 = 2

  func setEventSink(_ sink: @escaping @Sendable (CentralBackendEvent) -> Void) {
    lock.lock(); self.sink = sink; lock.unlock()
  }

  func emit(_ event: CentralBackendEvent) {
    lock.lock(); let sink = self.sink; lock.unlock()
    sink?(event)
  }

  func managerState() -> UInt64 {
    state
  }

  func startScan(serviceUUIDs _: [String]?) throws {}
  func stopScan() throws {}
  func connect(peripheralId _: Data) throws {}
  func disconnect(peripheralId _: Data) throws {}

  func discoverServices(peripheralId _: Data, serviceUUIDs _: [String]?) throws -> [String] {
    services
  }

  func discoverCharacteristics(peripheralId _: Data, serviceUUID _: String,
                               characteristicUUIDs _: [String]?) throws -> [String]
  {
    characteristics
  }

  func readCharacteristic(peripheralId _: Data, serviceUUID _: String,
                          characteristicUUID _: String) throws -> Data
  {
    readValue
  }

  func writeCharacteristic(
    peripheralId _: Data,
    serviceUUID _: String,
    characteristicUUID _: String,
    value _: Data,
    withResponse _: Bool
  ) throws {}

  func setNotify(peripheralId _: Data, serviceUUID _: String, characteristicUUID _: String,
                 enabled _: Bool) throws -> Bool
  {
    notifyResult
  }

  func readRSSI(peripheralId _: Data) throws -> Int64 {
    rssiValue
  }

  func peripheralState(peripheralId _: Data) throws -> UInt64 {
    peripheralStateValue
  }
}
