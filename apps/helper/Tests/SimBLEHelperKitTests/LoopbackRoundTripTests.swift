// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHelperKit
import SimBLEHostCore
import SimBLEProtocol
import XCTest

/// The protocol, the loopback transport, the capability token, and the central
/// service proven together against a fake backend, with no radio: present the token,
/// run a central op, read the response, read a streamed event, and reject a wrong token.
final class LoopbackRoundTripTests: XCTestCase {
  private let peripheralId = Data([0xDE, 0xAD, 0xBE, 0xEF])
  private let serviceUUID = "180D"
  private let charUUID = "2A37"

  private func startListener(_ backend: FakeCentralBackend, token: CapabilityToken,
                             peripheral: FakePeripheralBackend = FakePeripheralBackend())
    throws -> LoopbackListener
  {
    let listener = LoopbackListener(
      router: RequestRouter(service: CentralService(backend: backend),
                            peripheralService: PeripheralService(backend: peripheral),
                            gate: AuthGate(session: token))
    )
    try listener.start()
    XCTAssertGreaterThan(listener.port, 0)
    return listener
  }

  func testHelloNegotiatesTheVersion() throws {
    let token = CapabilityToken()
    let listener = try startListener(FakeCentralBackend(), token: token)
    defer { listener.stop() }
    let client = try LoopbackClient(port: listener.port)
    XCTAssertEqual(try client.send(.hello(version: 1), token: token), .hello(version: 1))
  }

  func testCentralStateRoundTrips() throws {
    let backend = FakeCentralBackend()
    backend.state = Wire.managerStatePoweredOn
    let token = CapabilityToken()
    let listener = try startListener(backend, token: token)
    defer { listener.stop() }
    let client = try LoopbackClient(port: listener.port)
    XCTAssertEqual(try client.send(.centralState, token: token),
                   .centralState(state: Wire.managerStatePoweredOn))
  }

  func testConnectThenReadRoundTrips() throws {
    let backend = FakeCentralBackend()
    backend.readValue = Data([0x01, 0x02, 0x03])
    let token = CapabilityToken()
    let listener = try startListener(backend, token: token)
    defer { listener.stop() }
    let client = try LoopbackClient(port: listener.port)

    XCTAssertEqual(try client.send(.connect(peripheralId: peripheralId), token: token),
                   .connected(peripheralId: peripheralId))
    let response = try client.send(
      .readCharacteristic(peripheralId: peripheralId, serviceUUID: serviceUUID,
                          characteristicUUID: charUUID), token: token
    )
    XCTAssertEqual(response, .characteristicValue(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID,
      value: Data([0x01, 0x02, 0x03])
    ))
  }

  func testWriteRoundTrips() throws {
    let token = CapabilityToken()
    let listener = try startListener(FakeCentralBackend(), token: token)
    defer { listener.stop() }
    let client = try LoopbackClient(port: listener.port)
    let response = try client.send(.writeCharacteristic(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID,
      value: Data([0xAA]), writeType: .withResponse
    ), token: token)
    XCTAssertEqual(response, .wrote)
  }

  func testStreamedEventReachesTheClient() throws {
    let backend = FakeCentralBackend()
    let token = CapabilityToken()
    let listener = try startListener(backend, token: token)
    defer { listener.stop() }
    let client = try LoopbackClient(port: listener.port)

    // Start a scan, then push a discovery through the backend; the listener streams it back.
    XCTAssertEqual(try client.send(.scanStart(serviceUUIDs: nil), token: token), .scanStarted)
    backend.emit(.discovered(peripheralId: peripheralId, localName: "Sensor",
                             serviceUUIDs: ["180D"], txPower: nil, manufacturerData: nil,
                             rssi: -40))
    XCTAssertEqual(try client.receiveEvent(), .discovered(
      peripheralId: peripheralId,
      advertisement: Advertisement(localName: "Sensor", serviceUUIDs: ["180D"]),
      rssi: -40
    ))
  }

  func testNotificationStreamsAsACharacteristicValueEvent() throws {
    let backend = FakeCentralBackend()
    let token = CapabilityToken()
    let listener = try startListener(backend, token: token)
    defer { listener.stop() }
    let client = try LoopbackClient(port: listener.port)

    XCTAssertEqual(try client.send(.setNotify(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID,
      enabled: true
    ), token: token),
    .notifyState(peripheralId: peripheralId, serviceUUID: serviceUUID,
                 characteristicUUID: charUUID, enabled: true))
    backend.emit(.characteristicValue(peripheralId: peripheralId, serviceUUID: serviceUUID,
                                      characteristicUUID: charUUID, value: Data([0x5A])))
    XCTAssertEqual(try client.receiveEvent(), .characteristicValue(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID,
      value: Data([0x5A])
    ))
  }

  func testReadRSSIRoundTrips() throws {
    let backend = FakeCentralBackend()
    backend.rssiValue = -71
    let token = CapabilityToken()
    let listener = try startListener(backend, token: token)
    defer { listener.stop() }
    let client = try LoopbackClient(port: listener.port)
    XCTAssertEqual(try client.send(.readRSSI(peripheralId: peripheralId), token: token),
                   .rssi(peripheralId: peripheralId, rssi: -71))
  }

  func testWrongTokenIsRejectedOverLoopback() throws {
    let token = CapabilityToken()
    let listener = try startListener(FakeCentralBackend(), token: token)
    defer { listener.stop() }
    let client = try LoopbackClient(port: listener.port)
    guard case let .failure(_, code, _) = try client.send(.centralState,
                                                          token: CapabilityToken())
    else {
      return XCTFail("a wrong token must come back as a failure")
    }
    XCTAssertEqual(code, BridgeErrorCode.unauthorized)
  }

  func testPeripheralRoleOpRoutesToThePeripheralService() throws {
    let token = CapabilityToken()
    let listener = try startListener(FakeCentralBackend(), token: token)
    defer { listener.stop() }
    let client = try LoopbackClient(port: listener.port)
    XCTAssertEqual(try client.send(.stopAdvertising, token: token), .advertisingStopped)
  }

  func testPeripheralEventStreamsToTheClient() throws {
    let token = CapabilityToken()
    let peripheral = FakePeripheralBackend()
    let listener = try startListener(FakeCentralBackend(), token: token, peripheral: peripheral)
    defer { listener.stop() }
    let client = try LoopbackClient(port: listener.port)

    XCTAssertEqual(try client.send(
      .startAdvertising(localName: "Sensor", serviceUUIDs: ["180D"]), token: token
    ), .advertisingStarted)
    peripheral.emit(.readRequest(requestId: 1, serviceUUID: serviceUUID,
                                 characteristicUUID: charUUID, offset: 0, centralId: peripheralId))
    XCTAssertEqual(try client.receiveEvent(), .readRequest(
      requestId: 1, serviceUUID: serviceUUID, characteristicUUID: charUUID, offset: 0,
      centralId: peripheralId
    ))
  }
}
