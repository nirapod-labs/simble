// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLEProtocol

/// The op the router calls. It takes a decoded protocol request, drives the
/// injected backend, and produces the protocol response; it forwards the
/// backend's unsolicited events to a sink the router installs, mapped to protocol
/// events. The backend is injected, so tests run it against a fake with no radio.
///
/// This service handles the central role. The router routes a peripheral-role request
/// to the peripheral service instead.
public final class CentralService: @unchecked Sendable {
  private let backend: CentralBackend
  private let peripheralSupported: Bool

  /// Build the service over the backend it drives. The CLI helper injects the real
  /// `CoreBluetoothCentral`; tests inject a fake. `peripheralSupported` reports whether
  /// the peripheral bridge is wired, surfaced in `hostStatus`.
  public init(backend: CentralBackend, peripheralSupported: Bool = false) {
    self.backend = backend
    self.peripheralSupported = peripheralSupported
  }

  /// Forward backend events to `sink`, mapped to protocol events. The router sets this
  /// once and writes each event back to the connected client as an event frame.
  public func onEvent(_ sink: @escaping @Sendable (Event) -> Void) {
    backend.setEventSink { event in
      sink(Self.event(from: event))
    }
  }

  /// The current host status, read straight from the backend's central manager state.
  /// `centralSupported` is true once the backend reaches `poweredOn`; `peripheralSupported`
  /// reports the value the service was built with.
  public func hostStatus() -> HostStatus {
    let state = backend.managerState()
    return HostStatus(centralSupported: state == Wire.managerStatePoweredOn,
                      peripheralSupported: peripheralSupported, centralState: state)
  }

  /// Drive `request` against the backend and produce its response. A backend failure
  /// becomes a protocol failure carrying the device code; an unexpected error becomes a
  /// generic failure. The op is echoed so the client correlates the reply.
  public func handle(_ request: Request) -> Response {
    do {
      switch request {
      case let .hello(version):
        return version == Wire.version1
          ? .hello(version: Wire.version1)
          : .failure(op: Wire.op(of: request), code: Self.unsupported,
                     message: "unsupported protocol version \(version)")
      case .centralState:
        return .centralState(state: backend.managerState())
      case let .scanStart(serviceUUIDs):
        try backend.startScan(serviceUUIDs: serviceUUIDs)
        return .scanStarted
      case .scanStop:
        try backend.stopScan()
        return .scanStopped
      case let .connect(peripheralId):
        try backend.connect(peripheralId: peripheralId)
        return .connected(peripheralId: peripheralId)
      case let .disconnect(peripheralId):
        try backend.disconnect(peripheralId: peripheralId)
        return .disconnected(peripheralId: peripheralId)
      case let .discoverServices(peripheralId, serviceUUIDs):
        let discovered = try backend.discoverServices(peripheralId: peripheralId,
                                                      serviceUUIDs: serviceUUIDs)
        return .servicesDiscovered(peripheralId: peripheralId, serviceUUIDs: discovered)
      case let .discoverCharacteristics(peripheralId, serviceUUID, characteristicUUIDs):
        let discovered = try backend.discoverCharacteristics(
          peripheralId: peripheralId, serviceUUID: serviceUUID,
          characteristicUUIDs: characteristicUUIDs
        )
        return .characteristicsDiscovered(peripheralId: peripheralId, serviceUUID: serviceUUID,
                                          characteristicUUIDs: discovered)
      case let .readCharacteristic(peripheralId, serviceUUID, characteristicUUID):
        let value = try backend.readCharacteristic(peripheralId: peripheralId,
                                                   serviceUUID: serviceUUID,
                                                   characteristicUUID: characteristicUUID)
        return .characteristicValue(peripheralId: peripheralId, serviceUUID: serviceUUID,
                                    characteristicUUID: characteristicUUID, value: value)
      case let .writeCharacteristic(peripheralId, serviceUUID, characteristicUUID, value, type):
        try backend.writeCharacteristic(peripheralId: peripheralId, serviceUUID: serviceUUID,
                                        characteristicUUID: characteristicUUID, value: value,
                                        withResponse: type == .withResponse)
        return .wrote
      case let .setNotify(peripheralId, serviceUUID, characteristicUUID, enabled):
        let state = try backend.setNotify(peripheralId: peripheralId, serviceUUID: serviceUUID,
                                          characteristicUUID: characteristicUUID, enabled: enabled)
        return .notifyState(peripheralId: peripheralId, serviceUUID: serviceUUID,
                            characteristicUUID: characteristicUUID, enabled: state)
      case let .readRSSI(peripheralId):
        return try .rssi(
          peripheralId: peripheralId,
          rssi: backend.readRSSI(peripheralId: peripheralId)
        )
      case let .peripheralState(peripheralId):
        return try .peripheralState(peripheralId: peripheralId,
                                    state: backend.peripheralState(peripheralId: peripheralId))
      default:
        // The router rejects a peripheral-role op before dispatch; this default is the
        // unreachable fallback.
        return .failure(op: Wire.op(of: request), code: Self.notImplemented,
                        message: "operation not implemented in the central bridge")
      }
    } catch let failure as CentralBackendError {
      return .failure(op: Wire.op(of: request), code: failure.code, message: failure.message)
    } catch {
      return .failure(op: Wire.op(of: request), code: Self.unsupported,
                      message: String(describing: error))
    }
  }

  /// Map a backend event to its protocol event.
  private static func event(from event: CentralBackendEvent) -> Event {
    switch event {
    case let .discovered(peripheralId, localName, serviceUUIDs, txPower, manufacturerData, rssi):
      let advertisement = Advertisement(localName: localName, serviceUUIDs: serviceUUIDs,
                                        txPower: txPower, manufacturerData: manufacturerData)
      return .discovered(peripheralId: peripheralId, advertisement: advertisement, rssi: rssi)
    case let .characteristicValue(peripheralId, serviceUUID, characteristicUUID, value):
      return .characteristicValue(peripheralId: peripheralId, serviceUUID: serviceUUID,
                                  characteristicUUID: characteristicUUID, value: value)
    case let .peripheralDisconnected(peripheralId, errorCode):
      return .peripheralDisconnected(peripheralId: peripheralId, errorCode: errorCode)
    case let .stateChanged(state):
      return .centralStateChanged(state: state)
    }
  }

  /// CBError.Code.unsupportedDevice (6) stands in for a request the bridge cannot serve.
  private static let unsupported: Int64 = 6
  /// A peripheral-role op the central bridge does not implement.
  private static let notImplemented: Int64 = 6
}
