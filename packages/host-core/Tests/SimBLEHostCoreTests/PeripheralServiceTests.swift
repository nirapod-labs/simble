// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHostCore
import SimBLEProtocol
import XCTest

/// Dispatch from a decoded peripheral-role request to a response, against a fake
/// backend so the suite runs with no radio. Each case proves one op drives the backend
/// and shapes the response, plus the event mapping and the failure path.
final class PeripheralServiceTests: XCTestCase {
  private let serviceUUID = "180D"
  private let charUUID = "2A37"
  private let centralId = Data([0xDE, 0xAD, 0xBE, 0xEF])

  func testAddServiceCarriesTheSpecAndConfirms() {
    let backend = FakePeripheralBackend()
    let service = PeripheralService(backend: backend)
    let spec = CharacteristicSpec(uuid: charUUID, properties: 0x12, permissions: 0x01)
    XCTAssertEqual(
      service.handle(.addService(serviceUUID: serviceUUID, isPrimary: true,
                                 characteristics: [spec])),
      .serviceAdded(serviceUUID: serviceUUID)
    )
    XCTAssertEqual(backend.commands, ["addService"])
    XCTAssertEqual(backend.lastService?.uuid, serviceUUID)
    XCTAssertEqual(backend.lastService?.isPrimary, true)
    XCTAssertEqual(backend.lastService?.characteristics, [spec])
  }

  func testRemoveServiceConfirms() {
    let backend = FakePeripheralBackend()
    let service = PeripheralService(backend: backend)
    XCTAssertEqual(service.handle(.removeService(serviceUUID: serviceUUID)),
                   .serviceRemoved(serviceUUID: serviceUUID))
    XCTAssertEqual(backend.commands, ["removeService"])
  }

  func testStartAdvertisingCarriesTheFilterAndConfirms() {
    let backend = FakePeripheralBackend()
    let service = PeripheralService(backend: backend)
    XCTAssertEqual(
      service.handle(.startAdvertising(localName: "Sensor", serviceUUIDs: ["180D"])),
      .advertisingStarted
    )
    XCTAssertEqual(backend.commands, ["startAdvertising"])
    XCTAssertEqual(backend.lastAdvertising?.localName, "Sensor")
    XCTAssertEqual(backend.lastAdvertising?.serviceUUIDs, ["180D"])
  }

  func testStopAdvertisingConfirms() {
    let backend = FakePeripheralBackend()
    let service = PeripheralService(backend: backend)
    XCTAssertEqual(service.handle(.stopAdvertising), .advertisingStopped)
    XCTAssertEqual(backend.commands, ["stopAdvertising"])
  }

  func testRespondReadCarriesTheValueAndConfirms() {
    let backend = FakePeripheralBackend()
    let service = PeripheralService(backend: backend)
    XCTAssertEqual(
      service.handle(.respondRead(requestId: 7, value: Data([0x48, 0x49]), attError: 0)),
      .readResponded
    )
    XCTAssertEqual(backend.lastReadResponse?.requestId, 7)
    XCTAssertEqual(backend.lastReadResponse?.value, Data([0x48, 0x49]))
    XCTAssertEqual(backend.lastReadResponse?.attError, 0)
  }

  func testRespondWriteCarriesTheResultAndConfirms() {
    let backend = FakePeripheralBackend()
    let service = PeripheralService(backend: backend)
    XCTAssertEqual(service.handle(.respondWrite(requestId: 9, attError: 0)), .writeResponded)
    XCTAssertEqual(backend.lastWriteResponse?.requestId, 9)
    XCTAssertEqual(backend.lastWriteResponse?.attError, 0)
  }

  func testUpdateValueCarriesTheTargetAndConfirms() {
    let backend = FakePeripheralBackend()
    let service = PeripheralService(backend: backend)
    XCTAssertEqual(
      service.handle(.updateValue(serviceUUID: serviceUUID, characteristicUUID: charUUID,
                                  value: Data([0x5A]), centralId: centralId)),
      .valueUpdated
    )
    XCTAssertEqual(backend.lastUpdate?.serviceUUID, serviceUUID)
    XCTAssertEqual(backend.lastUpdate?.characteristicUUID, charUUID)
    XCTAssertEqual(backend.lastUpdate?.value, Data([0x5A]))
    XCTAssertEqual(backend.lastUpdate?.centralId, centralId)
  }

  func testStateChangeSurfacesAsAPeripheralStateChangedEvent() {
    let backend = FakePeripheralBackend()
    let service = PeripheralService(backend: backend)
    let collector = EventCollector()
    service.onEvent { collector.append($0) }
    backend.emit(.stateChanged(state: Wire.managerStatePoweredOn))
    XCTAssertEqual(collector.all,
                   [.peripheralStateChanged(state: Wire.managerStatePoweredOn)])
  }

  func testReadRequestSurfacesAsAReadRequestEvent() {
    let backend = FakePeripheralBackend()
    let service = PeripheralService(backend: backend)
    let collector = EventCollector()
    service.onEvent { collector.append($0) }
    backend.emit(.readRequest(requestId: 3, serviceUUID: serviceUUID,
                              characteristicUUID: charUUID, offset: 0, centralId: centralId))
    XCTAssertEqual(collector.all, [.readRequest(
      requestId: 3, serviceUUID: serviceUUID, characteristicUUID: charUUID, offset: 0,
      centralId: centralId
    )])
  }

  func testWriteRequestSurfacesAsAWriteRequestEvent() {
    let backend = FakePeripheralBackend()
    let service = PeripheralService(backend: backend)
    let collector = EventCollector()
    service.onEvent { collector.append($0) }
    backend.emit(.writeRequest(requestId: 4, serviceUUID: serviceUUID,
                               characteristicUUID: charUUID, value: Data([0x01]), offset: 0,
                               centralId: centralId))
    XCTAssertEqual(collector.all, [.writeRequest(
      requestId: 4, serviceUUID: serviceUUID, characteristicUUID: charUUID, value: Data([0x01]),
      offset: 0, centralId: centralId
    )])
  }

  func testSubscriptionEventsSurface() {
    let backend = FakePeripheralBackend()
    let service = PeripheralService(backend: backend)
    let collector = EventCollector()
    service.onEvent { collector.append($0) }
    backend.emit(.subscribed(serviceUUID: serviceUUID, characteristicUUID: charUUID,
                             centralId: centralId, mtu: 185))
    backend.emit(.unsubscribed(serviceUUID: serviceUUID, characteristicUUID: charUUID,
                               centralId: centralId))
    backend.emit(.readyToUpdate)
    XCTAssertEqual(collector.all, [
      .subscribed(serviceUUID: serviceUUID, characteristicUUID: charUUID, centralId: centralId,
                  mtu: 185),
      .unsubscribed(serviceUUID: serviceUUID, characteristicUUID: charUUID, centralId: centralId),
      .readyToUpdate,
    ])
  }

  func testBackendFailureBecomesAProtocolFailureWithTheDeviceCode() {
    let backend = FakePeripheralBackend()
    backend.failWith = PeripheralBackendError(code: 4, message: "service not published")
    let service = PeripheralService(backend: backend)
    guard case let .failure(op, code, _) = service.handle(.removeService(serviceUUID: serviceUUID))
    else { return XCTFail("a backend failure must surface as a protocol failure") }
    XCTAssertEqual(op, Wire.op(of: .removeService(serviceUUID: serviceUUID)))
    XCTAssertEqual(code, 4)
  }
}
