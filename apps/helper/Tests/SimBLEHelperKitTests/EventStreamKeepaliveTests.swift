// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHelperKit
import SimBLEHostCore
import SimBLEProtocol
import XCTest

/// The helper's event channel must outlive an idle socket read deadline. A connection that
/// only receives events sends no requests, so its read sits at the frame boundary until the
/// deadline; reaching the deadline must not drop the connection or detach its event sink. The
/// listener takes a short deadline here so the idle gap is reached without a long wait.
final class EventStreamKeepaliveTests: XCTestCase {
  private let serviceUUID = "180D"
  private let charUUID = "2A37"
  private let centralId = Data([0xAB, 0xCD])

  func testEventStreamSurvivesAnIdleReadDeadline() throws {
    let token = CapabilityToken()
    let peripheral = FakePeripheralBackend()
    let listener = LoopbackListener(
      router: RequestRouter(service: CentralService(backend: FakeCentralBackend()),
                            peripheralService: PeripheralService(backend: peripheral),
                            gate: AuthGate(session: token)),
      idleTimeoutSeconds: 0.3
    )
    try listener.start()
    defer { listener.stop() }
    let client = try LoopbackClient(port: listener.port)

    XCTAssertEqual(try client.send(
      .startAdvertising(localName: "Sensor", serviceUUIDs: [serviceUUID]), token: token
    ), .advertisingStarted)

    // Idle for several multiples of the read deadline before any event is emitted.
    Thread.sleep(forTimeInterval: 1.0)

    peripheral.emit(.readRequest(requestId: 7, serviceUUID: serviceUUID,
                                 characteristicUUID: charUUID, offset: 0, centralId: centralId))
    XCTAssertEqual(try client.receiveEvent(), .readRequest(
      requestId: 7, serviceUUID: serviceUUID, characteristicUUID: charUUID, offset: 0,
      centralId: centralId
    ))
  }
}
