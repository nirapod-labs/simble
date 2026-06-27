// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHostCore
import SimBLEProtocol
import XCTest

/// Dispatch from a decoded request to a response, against a fake backend so the
/// suite runs with no radio. Each case proves one op drives the backend and shapes
/// the response, plus the event mapping and the failure path.
final class CentralServiceTests: XCTestCase {
  private let peripheralId = Data([0xDE, 0xAD, 0xBE, 0xEF])
  private let serviceUUID = "180D"
  private let charUUID = "2A37"

  func testHelloEchoesTheVersion() {
    let service = CentralService(backend: FakeCentralBackend())
    XCTAssertEqual(service.handle(.hello(version: Wire.version1)), .hello(version: Wire.version1))
  }

  func testHelloRejectsAnUnsupportedVersion() {
    let service = CentralService(backend: FakeCentralBackend())
    guard case .failure = service.handle(.hello(version: 99)) else {
      return XCTFail("an unsupported version must fail")
    }
  }

  func testCentralStateReadsTheManagerState() {
    let backend = FakeCentralBackend()
    backend.state = 4 // CBManagerState.unauthorized
    let service = CentralService(backend: backend)
    XCTAssertEqual(service.handle(.centralState), .centralState(state: 4))
  }

  func testScanStartCarriesTheFilterAndConfirms() {
    let backend = FakeCentralBackend()
    let service = CentralService(backend: backend)
    XCTAssertEqual(service.handle(.scanStart(serviceUUIDs: ["180D"])), .scanStarted)
    XCTAssertEqual(backend.commands, ["startScan"])
    XCTAssertEqual(backend.lastScanFilter, ["180D"])
  }

  func testScanEmitsDiscoveredEvent() {
    let backend = FakeCentralBackend()
    let service = CentralService(backend: backend)
    let collector = EventCollector()
    service.onEvent { collector.append($0) }
    _ = service.handle(.scanStart(serviceUUIDs: nil))
    backend.emit(.discovered(peripheralId: peripheralId, localName: "Sensor",
                             serviceUUIDs: ["180D"], txPower: 4, manufacturerData: Data([0x01]),
                             rssi: -42))
    XCTAssertEqual(collector.all, [.discovered(
      peripheralId: peripheralId,
      advertisement: Advertisement(localName: "Sensor", serviceUUIDs: ["180D"], txPower: 4,
                                   manufacturerData: Data([0x01])),
      rssi: -42
    )])
  }

  func testConnectReturnsTheConnectedPeripheral() {
    let backend = FakeCentralBackend()
    let service = CentralService(backend: backend)
    XCTAssertEqual(service.handle(.connect(peripheralId: peripheralId)),
                   .connected(peripheralId: peripheralId))
    XCTAssertEqual(backend.commands, ["connect"])
  }

  func testDiscoverServicesReturnsTheList() {
    let backend = FakeCentralBackend()
    backend.services = ["180D", "180F"]
    let service = CentralService(backend: backend)
    XCTAssertEqual(service.handle(.discoverServices(peripheralId: peripheralId, serviceUUIDs: nil)),
                   .servicesDiscovered(peripheralId: peripheralId, serviceUUIDs: ["180D", "180F"]))
  }

  func testDiscoverCharacteristicsReturnsTheList() {
    let backend = FakeCentralBackend()
    backend.characteristics = ["2A37", "2A38"]
    let service = CentralService(backend: backend)
    let response = service.handle(.discoverCharacteristics(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUIDs: nil
    ))
    XCTAssertEqual(response, .characteristicsDiscovered(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUIDs: ["2A37", "2A38"]
    ))
  }

  func testReadReturnsTheValue() {
    let backend = FakeCentralBackend()
    backend.readValue = Data([0x48, 0x49])
    let service = CentralService(backend: backend)
    let response = service.handle(.readCharacteristic(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID
    ))
    XCTAssertEqual(response, .characteristicValue(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID,
      value: Data([0x48, 0x49])
    ))
  }

  func testWriteWithoutResponseRecordsTheType() {
    let backend = FakeCentralBackend()
    let service = CentralService(backend: backend)
    let response = service.handle(.writeCharacteristic(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID,
      value: Data([0x01, 0x02]), writeType: .withoutResponse
    ))
    XCTAssertEqual(response, .wrote)
    XCTAssertEqual(backend.lastWrite?.value, Data([0x01, 0x02]))
    XCTAssertEqual(backend.lastWrite?.withResponse, false)
  }

  func testSetNotifyReturnsTheState() {
    let backend = FakeCentralBackend()
    backend.notifyResult = true
    let service = CentralService(backend: backend)
    let response = service.handle(.setNotify(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID,
      enabled: true
    ))
    XCTAssertEqual(response, .notifyState(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID,
      enabled: true
    ))
  }

  func testNotificationSurfacesAsACharacteristicValueEvent() {
    let backend = FakeCentralBackend()
    let service = CentralService(backend: backend)
    let collector = EventCollector()
    service.onEvent { collector.append($0) }
    _ = service.handle(.setNotify(peripheralId: peripheralId, serviceUUID: serviceUUID,
                                  characteristicUUID: charUUID, enabled: true))
    backend.emit(.characteristicValue(peripheralId: peripheralId, serviceUUID: serviceUUID,
                                      characteristicUUID: charUUID, value: Data([0x5A])))
    XCTAssertEqual(collector.all, [.characteristicValue(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID,
      value: Data([0x5A])
    )])
  }

  func testReadRSSIReturnsTheValue() {
    let backend = FakeCentralBackend()
    backend.rssiValue = -67
    let service = CentralService(backend: backend)
    XCTAssertEqual(service.handle(.readRSSI(peripheralId: peripheralId)),
                   .rssi(peripheralId: peripheralId, rssi: -67))
  }

  func testDisconnectEventSurfaces() {
    let backend = FakeCentralBackend()
    let service = CentralService(backend: backend)
    let collector = EventCollector()
    service.onEvent { collector.append($0) }
    backend.emit(.peripheralDisconnected(peripheralId: peripheralId, errorCode: 7))
    backend.emit(.stateChanged(state: 5))
    XCTAssertEqual(collector.all, [
      .peripheralDisconnected(peripheralId: peripheralId, errorCode: 7),
      .centralStateChanged(state: 5),
    ])
  }

  func testBackendFailureBecomesAProtocolFailureWithTheDeviceCode() {
    let backend = FakeCentralBackend()
    backend.failWith = CentralBackendError(code: 4, message: "characteristic not discovered")
    let service = CentralService(backend: backend)
    guard case let .failure(op, code, _) = service.handle(.readCharacteristic(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID
    ))
    else { return XCTFail("a backend failure must surface as a protocol failure") }
    XCTAssertEqual(op, Wire.op(of: .readCharacteristic(
      peripheralId: peripheralId, serviceUUID: serviceUUID, characteristicUUID: charUUID
    )))
    XCTAssertEqual(code, 4)
  }

  func testPeripheralRoleOpReturnsNotImplemented() {
    let service = CentralService(backend: FakeCentralBackend())
    guard case .failure = service.handle(.stopAdvertising) else {
      return XCTFail("a peripheral-role op must fail not-implemented in the central bridge")
    }
  }

  func testHostStatusReflectsTheManagerState() {
    let backend = FakeCentralBackend()
    backend.state = Wire.managerStatePoweredOn
    let poweredOn = CentralService(backend: backend).hostStatus()
    XCTAssertTrue(poweredOn.centralSupported)
    XCTAssertEqual(poweredOn.centralState, Wire.managerStatePoweredOn)
    XCTAssertFalse(poweredOn.peripheralSupported)

    backend.state = 4 // unauthorized
    let off = CentralService(backend: backend).hostStatus()
    XCTAssertFalse(off.centralSupported)
    XCTAssertEqual(off.centralState, 4)
  }
}
