// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLEProtocol

/// The op the router calls for a peripheral-role request. It takes a decoded protocol
/// request, drives the injected backend, and produces the protocol response; it
/// forwards the backend's unsolicited events to a sink the router installs, mapped to
/// protocol events. The backend is injected, so tests run it against a fake with no
/// radio.
///
/// The router routes a peripheral-role request here and every other request to the
/// central service.
public final class PeripheralService: @unchecked Sendable {
  private let backend: PeripheralBackend

  /// Build the service over the backend it drives. The CLI helper injects the real
  /// `CoreBluetoothPeripheral`; tests inject a fake.
  public init(backend: PeripheralBackend) {
    self.backend = backend
  }

  /// Forward backend events to `sink`, mapped to protocol events. The router sets this
  /// once and writes each event back to the connected client as an event frame.
  public func onEvent(_ sink: @escaping @Sendable (Event) -> Void) {
    backend.setEventSink { event in
      sink(Self.event(from: event))
    }
  }

  /// Drive `request` against the backend and produce its response. A backend failure
  /// becomes a protocol failure carrying the device code; an unexpected error becomes a
  /// generic failure. The op is echoed so the client correlates the reply.
  public func handle(_ request: Request) -> Response {
    do {
      switch request {
      case let .addService(serviceUUID, isPrimary, characteristics):
        try backend.addService(serviceUUID: serviceUUID, isPrimary: isPrimary,
                               characteristics: characteristics)
        return .serviceAdded(serviceUUID: serviceUUID)
      case let .removeService(serviceUUID):
        try backend.removeService(serviceUUID: serviceUUID)
        return .serviceRemoved(serviceUUID: serviceUUID)
      case let .startAdvertising(localName, serviceUUIDs):
        try backend.startAdvertising(localName: localName, serviceUUIDs: serviceUUIDs)
        return .advertisingStarted
      case .stopAdvertising:
        try backend.stopAdvertising()
        return .advertisingStopped
      case let .respondRead(requestId, value, attError):
        try backend.respondRead(requestId: requestId, value: value, attError: attError)
        return .readResponded
      case let .respondWrite(requestId, attError):
        try backend.respondWrite(requestId: requestId, attError: attError)
        return .writeResponded
      case let .updateValue(serviceUUID, characteristicUUID, value, centralId):
        try backend.updateValue(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID,
                                value: value, centralId: centralId)
        return .valueUpdated
      default:
        // The router routes only a peripheral-role op here; this default is the
        // unreachable fallback.
        return .failure(op: Wire.op(of: request), code: Self.notImplemented,
                        message: "operation not implemented in the peripheral bridge")
      }
    } catch let failure as PeripheralBackendError {
      return .failure(op: Wire.op(of: request), code: failure.code, message: failure.message)
    } catch {
      return .failure(op: Wire.op(of: request), code: Self.unsupported,
                      message: String(describing: error))
    }
  }

  /// Map a backend event to its protocol event.
  private static func event(from event: PeripheralBackendEvent) -> Event {
    switch event {
    case let .stateChanged(state):
      .peripheralStateChanged(state: state)
    case let .readRequest(requestId, serviceUUID, characteristicUUID, offset, centralId):
      .readRequest(requestId: requestId, serviceUUID: serviceUUID,
                   characteristicUUID: characteristicUUID, offset: offset,
                   centralId: centralId)
    case let .writeRequest(requestId, serviceUUID, characteristicUUID, value, offset, centralId):
      .writeRequest(requestId: requestId, serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID, value: value, offset: offset,
                    centralId: centralId)
    case let .subscribed(serviceUUID, characteristicUUID, centralId, mtu):
      .subscribed(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID,
                  centralId: centralId, mtu: mtu)
    case let .unsubscribed(serviceUUID, characteristicUUID, centralId):
      .unsubscribed(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID,
                    centralId: centralId)
    case .readyToUpdate:
      .readyToUpdate
    }
  }

  /// CBError.Code.unsupportedDevice (6) stands in for a request the bridge cannot serve.
  private static let unsupported: Int64 = 6
  /// A non-peripheral-role op the peripheral bridge does not implement.
  private static let notImplemented: Int64 = 6
}
