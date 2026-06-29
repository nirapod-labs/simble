// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLEProtocol

/// An unsolicited event a peripheral learns without asking: a manager-state change,
/// an incoming read or write request, a central subscribing or unsubscribing, or the
/// transmit queue draining. The backend hands these to a sink the service installs;
/// the service turns each into a protocol event frame.
public enum PeripheralBackendEvent: Equatable, Sendable {
  /// The peripheral manager's `CBManagerState` changed.
  case stateChanged(state: UInt64)
  /// A connected central asked to read a local characteristic; answer with `respondRead`
  /// carrying the same `requestId`.
  case readRequest(requestId: UInt64, serviceUUID: String, characteristicUUID: String,
                   offset: UInt64, centralId: Data)
  /// A connected central asked to write a local characteristic; answer with `respondWrite`
  /// carrying the same `requestId`.
  case writeRequest(requestId: UInt64, serviceUUID: String, characteristicUUID: String,
                    value: Data, offset: UInt64, centralId: Data)
  /// A central subscribed to a local characteristic; `mtu` is its maximum update value length.
  case subscribed(serviceUUID: String, characteristicUUID: String, centralId: Data, mtu: UInt64)
  /// A central unsubscribed from a local characteristic.
  case unsubscribed(serviceUUID: String, characteristicUUID: String, centralId: Data)
  /// The transmit queue has room again after a failed `updateValue`.
  case readyToUpdate
}

/// Why a backend command failed, carrying a device-shaped `CBError`/`CBATTError`
/// numeric code and a human-readable reason that is never load-bearing.
public struct PeripheralBackendError: Error, Equatable, Sendable {
  /// A `CBError`/`CBATTError` raw value, for device parity.
  public let code: Int64
  /// A human-readable reason for logs; the code is what callers branch on.
  public let message: String

  /// Wrap a failure with its device code and reason.
  public init(code: Int64, message: String) {
    self.code = code
    self.message = message
  }
}

/// The CoreBluetooth peripheral operations the bridge drives, abstracted so the
/// service runs against a fake on a radio-less runner and against the real radio
/// on a Mac. Each command blocks until its CoreBluetooth delegate callback fires
/// or the backend times out; unsolicited results arrive through the event sink.
///
/// The bridge moves GATT traffic only. No pairing secret, bonding record, or key
/// material crosses this surface.
public protocol PeripheralBackend: AnyObject, Sendable {
  /// Install the sink for unsolicited events. The service sets this once before
  /// driving any command; the backend calls it from its own queue.
  func setEventSink(_ sink: @escaping @Sendable (PeripheralBackendEvent) -> Void)

  /// The current `CBManagerState` raw value.
  func managerState() -> UInt64

  /// Publish a local GATT service with its characteristics.
  func addService(serviceUUID: String, isPrimary: Bool,
                  characteristics: [CharacteristicSpec]) throws

  /// Remove a previously published local service.
  func removeService(serviceUUID: String) throws

  /// Begin advertising, optionally with a local name and service UUIDs.
  func startAdvertising(localName: String?, serviceUUIDs: [String]?) throws

  /// Stop advertising.
  func stopAdvertising() throws

  /// Answer an incoming read request with a value and an ATT result.
  func respondRead(requestId: UInt64, value: Data, attError: UInt64) throws

  /// Answer an incoming write request with an ATT result.
  func respondWrite(requestId: UInt64, attError: UInt64) throws

  /// Push a new value for a local characteristic to the subscribed centrals, or to one
  /// central when `centralId` is set.
  func updateValue(serviceUUID: String, characteristicUUID: String, value: Data,
                   centralId: Data?) throws
}
