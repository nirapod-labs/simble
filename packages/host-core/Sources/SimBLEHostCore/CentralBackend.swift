// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation

/// An unsolicited event a central learns without asking: a scan result, a
/// subscribed characteristic's notification, an unexpected disconnect, or a
/// change in the manager's state. The backend hands these to a sink the service
/// installs; the service turns each into a protocol event frame.
public enum CentralBackendEvent: Equatable, Sendable {
  /// A peripheral seen while scanning, with the advertisement fields the radio surfaced.
  case discovered(peripheralId: Data, localName: String?, serviceUUIDs: [String]?,
                  txPower: Int64?, manufacturerData: Data?, rssi: Int64)
  /// A subscribed characteristic delivered a notification or indication.
  case characteristicValue(peripheralId: Data, serviceUUID: String, characteristicUUID: String,
                           value: Data)
  /// A peripheral disconnected unexpectedly; `errorCode` is the `CBError` raw value when one
  /// applied.
  case peripheralDisconnected(peripheralId: Data, errorCode: Int64?)
  /// A connect succeeded; the connection is up.
  case peripheralConnected(peripheralId: Data)
  /// A connect failed; `errorCode` is the `CBError` raw value when one applied.
  case peripheralConnectFailed(peripheralId: Data, errorCode: Int64?)
  /// The central manager's `CBManagerState` changed.
  case stateChanged(state: UInt64)
}

/// Why a backend command failed, carrying a device-shaped `CBError`/`CBATTError`
/// numeric code and a human-readable reason that is never load-bearing.
public struct CentralBackendError: Error, Equatable, Sendable {
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

/// The CoreBluetooth central operations the bridge drives, abstracted so the
/// service runs against a fake on a radio-less runner and against the real radio
/// on a Mac. Most commands block until their CoreBluetooth delegate callback fires
/// or the backend times out; connect returns once the request is issued, and its
/// outcome arrives through the event sink. Unsolicited results arrive there too.
///
/// The bridge moves GATT traffic only. No pairing secret, bonding record, or key
/// material crosses this surface.
public protocol CentralBackend: AnyObject, Sendable {
  /// Install the sink for unsolicited events. The service sets this once before
  /// driving any command; the backend calls it from its own queue.
  func setEventSink(_ sink: @escaping @Sendable (CentralBackendEvent) -> Void)

  /// The current `CBManagerState` raw value.
  func managerState() -> UInt64

  /// Start scanning, optionally filtered to the given service UUIDs.
  func startScan(serviceUUIDs: [String]?) throws

  /// Stop scanning.
  func stopScan() throws

  /// Connect to the peripheral named by its host identifier. Returns once the request is issued;
  /// the outcome arrives as a `peripheralConnected` or `peripheralConnectFailed` event.
  func connect(peripheralId: Data) throws

  /// Cancel the connection to the named peripheral.
  func disconnect(peripheralId: Data) throws

  /// Discover services on a connected peripheral, optionally filtered. Returns the
  /// discovered service UUIDs.
  func discoverServices(peripheralId: Data, serviceUUIDs: [String]?) throws -> [String]

  /// Discover characteristics of a service, optionally filtered. Returns the discovered
  /// characteristic UUIDs.
  func discoverCharacteristics(peripheralId: Data, serviceUUID: String,
                               characteristicUUIDs: [String]?) throws -> [String]

  /// Read one characteristic's value. Returns the value the peripheral reported.
  func readCharacteristic(peripheralId: Data, serviceUUID: String,
                          characteristicUUID: String) throws -> Data

  /// Write a characteristic's value, with or without a response.
  func writeCharacteristic(peripheralId: Data, serviceUUID: String, characteristicUUID: String,
                           value: Data, withResponse: Bool) throws

  /// Enable or disable notifications for a characteristic. Returns the resulting state.
  func setNotify(peripheralId: Data, serviceUUID: String, characteristicUUID: String,
                 enabled: Bool) throws -> Bool

  /// Read a connected peripheral's RSSI in dBm.
  func readRSSI(peripheralId: Data) throws -> Int64

  /// Read a connected peripheral's `CBPeripheralState` raw value.
  func peripheralState(peripheralId: Data) throws -> UInt64
}
