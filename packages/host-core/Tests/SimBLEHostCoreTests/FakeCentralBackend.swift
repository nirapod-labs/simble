// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHostCore
import SimBLEProtocol

/// A radio-free `CentralBackend` for the dispatch tests. It records each command,
/// returns canned results, exposes the event sink, and can fail a command with a
/// chosen device code. Deterministic, so the suite runs without Bluetooth.
final class FakeCentralBackend: CentralBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var sink: (@Sendable (CentralBackendEvent) -> Void)?

  /// The `CBManagerState` the fake reports; defaults to `poweredOn`.
  var state: UInt64 = Wire.managerStatePoweredOn
  /// Canned discovery, read, notify, RSSI, and peripheral-state results.
  var services: [String] = []
  var characteristics: [String] = []
  var readValue = Data()
  var notifyResult = true
  var rssiValue: Int64 = -50
  var peripheralStateValue: UInt64 = 2 // CBPeripheralState.connected
  /// When set, the next command throws this error.
  var failWith: CentralBackendError?

  /// The commands the fake received, in order.
  private(set) var commands: [String] = []
  /// The scan filter the last `startScan` carried.
  private(set) var lastScanFilter: [String]?
  /// The last write the fake received.
  private(set) var lastWrite: (value: Data, withResponse: Bool)?

  func setEventSink(_ sink: @escaping @Sendable (CentralBackendEvent) -> Void) {
    lock.lock(); self.sink = sink; lock.unlock()
  }

  /// Push an event to the installed sink.
  func emit(_ event: CentralBackendEvent) {
    lock.lock(); let sink = self.sink; lock.unlock()
    sink?(event)
  }

  func managerState() -> UInt64 {
    state
  }

  func startScan(serviceUUIDs: [String]?) throws {
    try checkFailure()
    record("startScan"); lastScanFilter = serviceUUIDs
  }

  func stopScan() throws {
    try checkFailure(); record("stopScan")
  }

  func connect(peripheralId _: Data) throws {
    try checkFailure(); record("connect")
  }

  func disconnect(peripheralId _: Data) throws {
    try checkFailure(); record("disconnect")
  }

  func discoverServices(peripheralId _: Data, serviceUUIDs _: [String]?) throws -> [String] {
    try checkFailure(); record("discoverServices"); return services
  }

  func discoverCharacteristics(peripheralId _: Data, serviceUUID _: String,
                               characteristicUUIDs _: [String]?) throws -> [String]
  {
    try checkFailure(); record("discoverCharacteristics"); return characteristics
  }

  func readCharacteristic(peripheralId _: Data, serviceUUID _: String,
                          characteristicUUID _: String) throws -> Data
  {
    try checkFailure(); record("readCharacteristic"); return readValue
  }

  func writeCharacteristic(
    peripheralId _: Data,
    serviceUUID _: String,
    characteristicUUID _: String,
    value: Data,
    withResponse: Bool
  ) throws {
    try checkFailure(); record("writeCharacteristic")
    lastWrite = (value, withResponse)
  }

  func setNotify(peripheralId _: Data, serviceUUID _: String, characteristicUUID _: String,
                 enabled _: Bool) throws -> Bool
  {
    try checkFailure(); record("setNotify"); return notifyResult
  }

  func readRSSI(peripheralId _: Data) throws -> Int64 {
    try checkFailure(); record("readRSSI"); return rssiValue
  }

  func peripheralState(peripheralId _: Data) throws -> UInt64 {
    try checkFailure(); record("peripheralState"); return peripheralStateValue
  }

  private func record(_ name: String) {
    lock.lock(); commands.append(name); lock.unlock()
  }

  private func checkFailure() throws {
    if let failWith { throw failWith }
  }
}

/// A thread-safe sink the service-event tests install, so a test reads back the events
/// the service forwarded without a captured-var data race.
final class EventCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [Event] = []

  func append(_ event: Event) {
    lock.lock(); events.append(event); lock.unlock()
  }

  var all: [Event] {
    lock.lock(); defer { lock.unlock() }
    return events
  }
}
