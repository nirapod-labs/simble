// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLEHostCore
import SimBLEProtocol

/// The `CBError`-style codes the helper returns for transport-level failures, distinct
/// from the device codes a backend failure carries.
enum BridgeErrorCode {
  /// A request that failed the capability-token gate.
  static let unauthorized: Int64 = -1
  /// A request whose bytes did not decode to a valid message.
  static let malformed: Int64 = -2
  /// A peripheral-role op the central bridge does not implement.
  static let notImplemented: Int64 = -3
}

/// Turns a request into a response by driving the central service, behind the
/// capability-token gate, and streams the service's events to the connected client.
/// One `CentralService` is shared across connections; the listener attaches a
/// per-connection event sink for the duration of a connection.
public final class RequestRouter: @unchecked Sendable {
  private let service: CentralService
  private let gate: AuthGate
  private let sinkLock = NSLock()
  private var eventSink: (@Sendable (Event) -> Void)?

  /// Build the router over the central service and the token gate. The router installs
  /// the service's event sink once and forwards each event to the attached connection.
  public init(service: CentralService, gate: AuthGate) {
    self.service = service
    self.gate = gate
    service.onEvent { [weak self] event in
      guard let self else { return }
      self.sinkLock.lock()
      let sink = self.eventSink
      self.sinkLock.unlock()
      sink?(event)
    }
  }

  /// Route the central service's events to `sink` for the life of one connection. The
  /// listener attaches before serving and detaches after.
  public func attachEventSink(_ sink: @escaping @Sendable (Event) -> Void) {
    sinkLock.lock()
    eventSink = sink
    sinkLock.unlock()
  }

  /// Stop routing events to the connection's sink.
  public func detachEventSink() {
    sinkLock.lock()
    eventSink = nil
    sinkLock.unlock()
  }

  /// Validate the token, then dispatch. The gate runs before the operation is interpreted,
  /// so a caller without the token learns nothing about the op surface beyond the auth
  /// failure. No token, no key material, crosses back on a response.
  public func respond(toPayload payload: Data) -> Response {
    guard let presented = (try? Wire.token(in: payload)).flatMap(CapabilityToken.init(bytes:)),
          gate.accepts(presented)
    else {
      return .failure(op: 0, code: BridgeErrorCode.unauthorized,
                      message: "invalid capability token")
    }
    let request: Request
    do {
      request = try Wire.decodeRequest(payload)
    } catch {
      return .failure(op: 0, code: BridgeErrorCode.malformed, message: String(describing: error))
    }
    // A peripheral-role op is rejected at the router, not dispatched: the central bridge
    // does not implement it in this version.
    guard !Wire.isPeripheralRole(request) else {
      return .failure(op: Wire.op(of: request), code: BridgeErrorCode.notImplemented,
                      message: "peripheral role not implemented in the central bridge")
    }
    return service.handle(request)
  }
}
