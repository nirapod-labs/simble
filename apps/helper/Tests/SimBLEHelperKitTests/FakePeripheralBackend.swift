// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLEHostCore
import SimBLEProtocol

/// A radio-free `PeripheralBackend` for the helper round-trip and router tests. It
/// accepts every command and exposes the event sink, so a loopback client drives a
/// full request-response and reads a streamed event without Bluetooth.
final class FakePeripheralBackend: PeripheralBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var sink: (@Sendable (PeripheralBackendEvent) -> Void)?

  var state: UInt64 = Wire.managerStatePoweredOn

  func setEventSink(_ sink: @escaping @Sendable (PeripheralBackendEvent) -> Void) {
    lock.lock(); self.sink = sink; lock.unlock()
  }

  func emit(_ event: PeripheralBackendEvent) {
    lock.lock(); let sink = self.sink; lock.unlock()
    sink?(event)
  }

  func managerState() -> UInt64 {
    state
  }

  func addService(serviceUUID _: String, isPrimary _: Bool,
                  characteristics _: [CharacteristicSpec]) throws {}
  func removeService(serviceUUID _: String) throws {}
  func startAdvertising(localName _: String?, serviceUUIDs _: [String]?) throws {}
  func stopAdvertising() throws {}
  func respondRead(requestId _: UInt64, value _: Data, attError _: UInt64) throws {}
  func respondWrite(requestId _: UInt64, attError _: UInt64) throws {}
  func updateValue(serviceUUID _: String, characteristicUUID _: String, value _: Data,
                   centralId _: Data?) throws {}
}
