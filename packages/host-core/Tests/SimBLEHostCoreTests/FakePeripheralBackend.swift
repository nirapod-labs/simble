// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHostCore
import SimBLEProtocol

/// A radio-free `PeripheralBackend` for the dispatch tests. It records each command,
/// exposes the event sink, and can fail a command with a chosen device code.
/// Deterministic, so the suite runs without Bluetooth.
final class FakePeripheralBackend: PeripheralBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var sink: (@Sendable (PeripheralBackendEvent) -> Void)?

  /// The `CBManagerState` the fake reports; defaults to `poweredOn`.
  var state: UInt64 = Wire.managerStatePoweredOn
  /// When set, the next command throws this error.
  var failWith: PeripheralBackendError?

  /// The commands the fake received, in order.
  private(set) var commands: [String] = []
  /// The last service the fake was asked to publish.
  private(set) var lastService: (
    uuid: String,
    isPrimary: Bool,
    characteristics: [CharacteristicSpec]
  )?
  /// The last advertising request the fake received.
  private(set) var lastAdvertising: (localName: String?, serviceUUIDs: [String]?)?
  /// The last read response the fake received.
  private(set) var lastReadResponse: (requestId: UInt64, value: Data, attError: UInt64)?
  /// The last write response the fake received.
  private(set) var lastWriteResponse: (requestId: UInt64, attError: UInt64)?
  /// The last value update the fake received.
  private(set) var lastUpdate: (serviceUUID: String, characteristicUUID: String, value: Data,
                                centralId: Data?)?

  func setEventSink(_ sink: @escaping @Sendable (PeripheralBackendEvent) -> Void) {
    lock.lock(); self.sink = sink; lock.unlock()
  }

  /// Push an event to the installed sink.
  func emit(_ event: PeripheralBackendEvent) {
    lock.lock(); let sink = self.sink; lock.unlock()
    sink?(event)
  }

  func managerState() -> UInt64 {
    state
  }

  func addService(serviceUUID: String, isPrimary: Bool,
                  characteristics: [CharacteristicSpec]) throws
  {
    try checkFailure(); record("addService")
    lastService = (serviceUUID, isPrimary, characteristics)
  }

  func removeService(serviceUUID _: String) throws {
    try checkFailure(); record("removeService")
  }

  func startAdvertising(localName: String?, serviceUUIDs: [String]?) throws {
    try checkFailure(); record("startAdvertising")
    lastAdvertising = (localName, serviceUUIDs)
  }

  func stopAdvertising() throws {
    try checkFailure(); record("stopAdvertising")
  }

  func respondRead(requestId: UInt64, value: Data, attError: UInt64) throws {
    try checkFailure(); record("respondRead")
    lastReadResponse = (requestId, value, attError)
  }

  func respondWrite(requestId: UInt64, attError: UInt64) throws {
    try checkFailure(); record("respondWrite")
    lastWriteResponse = (requestId, attError)
  }

  func updateValue(serviceUUID: String, characteristicUUID: String, value: Data,
                   centralId: Data?) throws
  {
    try checkFailure(); record("updateValue")
    lastUpdate = (serviceUUID, characteristicUUID, value, centralId)
  }

  private func record(_ name: String) {
    lock.lock(); commands.append(name); lock.unlock()
  }

  private func checkFailure() throws {
    if let failWith { throw failWith }
  }
}
