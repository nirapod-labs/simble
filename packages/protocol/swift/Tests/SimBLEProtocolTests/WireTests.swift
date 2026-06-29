// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

@testable import SimBLEProtocol
import XCTest

final class WireTests: XCTestCase {
  private let token = Data(repeating: 0xAB, count: 32)
  private let pid = Data([0x01, 0x02, 0x03, 0x04])
  private let cid = Data([0x09, 0x08])
  private let val = Data([0xDE, 0xAD, 0xBE])

  // MARK: Request round-trips

  func testHelloRoundTripsAndCarriesToken() throws {
    let payload = Wire.encode(.hello(version: 1), token: token)
    XCTAssertEqual(try Wire.decodeRequest(payload), .hello(version: 1))
    XCTAssertEqual(try Wire.token(in: payload), token)
  }

  func testHelloCarriesIdentity() throws {
    let payload = Wire.encode(.hello(version: 1), token: token, appID: "a", displayName: "App")
    XCTAssertEqual(payload.first, 0xA5)
    XCTAssertEqual(Wire.appID(in: payload), "a")
    XCTAssertEqual(Wire.appDisplayName(in: payload), "App")
    XCTAssertEqual(try Wire.decodeRequest(payload), .hello(version: 1))
    let bare = Wire.encode(.hello(version: 1), token: token)
    XCTAssertNil(Wire.appID(in: bare))
    XCTAssertNil(Wire.appDisplayName(in: bare))
  }

  func testTokenOnlyRequestsRoundTrip() throws {
    for request in [Request.centralState, .scanStop, .stopAdvertising] {
      let payload = Wire.encode(request, token: token)
      XCTAssertEqual(try Wire.decodeRequest(payload), request)
      XCTAssertEqual(try Wire.token(in: payload), token)
    }
  }

  func testScanStartRoundTrips() throws {
    let filtered = Request.scanStart(serviceUUIDs: ["180D", "180F"])
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(filtered, token: token)), filtered)
    let bare = Request.scanStart(serviceUUIDs: nil)
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(bare, token: token)), bare)
  }

  func testPeripheralRequestsRoundTrip() throws {
    for request in [Request.connect(peripheralId: pid), .disconnect(peripheralId: pid),
                    .readRSSI(peripheralId: pid), .peripheralState(peripheralId: pid)]
    {
      let payload = Wire.encode(request, token: token)
      XCTAssertEqual(try Wire.decodeRequest(payload), request)
      XCTAssertEqual(try Wire.token(in: payload), token)
    }
  }

  func testDiscoverRequestsRoundTrip() throws {
    let services = Request.discoverServices(peripheralId: pid, serviceUUIDs: ["180D"])
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(services, token: token)), services)
    let servicesAll = Request.discoverServices(peripheralId: pid, serviceUUIDs: nil)
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(servicesAll, token: token)), servicesAll)
    let chars = Request.discoverCharacteristics(peripheralId: pid, serviceUUID: "180D",
                                                characteristicUUIDs: ["2A37"])
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(chars, token: token)), chars)
  }

  func testReadWriteNotifyRequestsRoundTrip() throws {
    let read = Request.readCharacteristic(peripheralId: pid, serviceUUID: "180D",
                                          characteristicUUID: "2A37")
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(read, token: token)), read)
    let write = Request.writeCharacteristic(peripheralId: pid, serviceUUID: "180D",
                                            characteristicUUID: "2A37", value: val,
                                            writeType: .withoutResponse)
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(write, token: token)), write)
    let notify = Request.setNotify(peripheralId: pid, serviceUUID: "180D",
                                   characteristicUUID: "2A37", enabled: true)
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(notify, token: token)), notify)
  }

  func testAddServiceRoundTrips() throws {
    let chars = [CharacteristicSpec(uuid: "2A37", properties: 0x10, permissions: 0x01),
                 CharacteristicSpec(uuid: "2A38", properties: 0x08, permissions: 0x02)]
    let request = Request.addService(serviceUUID: "180D", isPrimary: true, characteristics: chars)
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(request, token: token)), request)
    let empty = Request.addService(serviceUUID: "180D", isPrimary: false, characteristics: [])
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(empty, token: token)), empty)
  }

  func testRemoveServiceAndAdvertisingRoundTrip() throws {
    let remove = Request.removeService(serviceUUID: "180D")
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(remove, token: token)), remove)
    let advert = Request.startAdvertising(localName: "Dev", serviceUUIDs: ["180D"])
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(advert, token: token)), advert)
    let bareAdvert = Request.startAdvertising(localName: nil, serviceUUIDs: nil)
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(bareAdvert, token: token)), bareAdvert)
  }

  func testRespondAndUpdateRequestsRoundTrip() throws {
    let respondRead = Request.respondRead(requestId: 7, value: val, attError: 0)
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(respondRead, token: token)), respondRead)
    let respondWrite = Request.respondWrite(requestId: 7, attError: 0)
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(respondWrite, token: token)), respondWrite)
    let update = Request.updateValue(serviceUUID: "180D", characteristicUUID: "2A37",
                                     value: val, centralId: cid)
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(update, token: token)), update)
    let broadcast = Request.updateValue(serviceUUID: "180D", characteristicUUID: "2A37",
                                        value: val, centralId: nil)
    XCTAssertEqual(try Wire.decodeRequest(Wire.encode(broadcast, token: token)), broadcast)
  }

  // MARK: Response round-trips

  func testResponsesRoundTrip() throws {
    let responses: [Response] = [
      .hello(version: 1),
      .centralState(state: 5),
      .scanStarted, .scanStopped,
      .connected(peripheralId: pid), .disconnected(peripheralId: pid),
      .servicesDiscovered(peripheralId: pid, serviceUUIDs: ["180D"]),
      .characteristicsDiscovered(peripheralId: pid, serviceUUID: "180D",
                                 characteristicUUIDs: ["2A37"]),
      .characteristicValue(peripheralId: pid, serviceUUID: "180D",
                           characteristicUUID: "2A37", value: val),
      .wrote,
      .notifyState(peripheralId: pid, serviceUUID: "180D", characteristicUUID: "2A37",
                   enabled: true),
      .rssi(peripheralId: pid, rssi: -42),
      .peripheralState(peripheralId: pid, state: 2),
      .serviceAdded(serviceUUID: "180D"), .serviceRemoved(serviceUUID: "180D"),
      .advertisingStarted, .advertisingStopped,
      .readResponded, .writeResponded, .valueUpdated,
      .failure(op: 5, code: -7, message: "no"),
    ]
    for response in responses {
      XCTAssertEqual(try Wire.decodeResponse(Wire.encode(response)), response)
    }
  }

  func testResponseNeverCarriesToken() {
    let payload = Wire.encode(.connected(peripheralId: pid))
    XCTAssertThrowsError(try Wire.token(in: payload))
  }

  // MARK: Event round-trips

  func testEventsRoundTrip() throws {
    let events: [Event] = [
      .discovered(peripheralId: pid,
                  advertisement: Advertisement(localName: "Dev", serviceUUIDs: ["180D"],
                                               txPower: -8, manufacturerData: Data([0xCA, 0xFE])),
                  rssi: -55),
      .discovered(peripheralId: pid, advertisement: Advertisement(), rssi: -60),
      .characteristicValue(peripheralId: pid, serviceUUID: "180D",
                           characteristicUUID: "2A37", value: val),
      .peripheralDisconnected(peripheralId: pid, errorCode: -10),
      .peripheralDisconnected(peripheralId: pid, errorCode: nil),
      .centralStateChanged(state: 4),
      .peripheralStateChanged(state: 5),
      .readRequest(requestId: 3, serviceUUID: "180D", characteristicUUID: "2A37",
                   offset: 0, centralId: cid),
      .writeRequest(requestId: 3, serviceUUID: "180D", characteristicUUID: "2A37",
                    value: val, offset: 1, centralId: cid),
      .subscribed(serviceUUID: "180D", characteristicUUID: "2A37", centralId: cid, mtu: 185),
      .unsubscribed(serviceUUID: "180D", characteristicUUID: "2A37", centralId: cid),
      .readyToUpdate,
    ]
    for event in events {
      XCTAssertEqual(try Wire.decodeEvent(Wire.encode(event)), event)
    }
  }

  func testEventNeverCarriesToken() {
    let payload = Wire.encode(.readyToUpdate)
    XCTAssertThrowsError(try Wire.token(in: payload))
  }

  func testEventOpsAreInTheHighRange() {
    // Every event op is at least 128, so a reader tells an event from a response at key 0.
    let discovered = Wire.encode(.discovered(peripheralId: pid, advertisement: Advertisement(),
                                             rssi: 0))
    // map header, key 0, then op as a 1-byte uint (0x18 0x80 = 128).
    XCTAssertEqual(discovered[discovered.startIndex + 2], 0x18)
    XCTAssertEqual(discovered[discovered.startIndex + 3], 0x80)
  }

  // MARK: Reject paths

  func testUnknownRequestOpcodeRejected() {
    // map { 0: 100 } with op 100, above every defined command op and below the event range.
    XCTAssertThrowsError(try Wire.decodeRequest(Data([0xA1, 0x00, 0x18, 0x64]))) { error in
      XCTAssertEqual(error as? ProtocolError, .badOpcode(100))
    }
  }

  func testUnknownEventOpcodeRejected() {
    // An event op at 200 (0xC8) is not defined.
    XCTAssertThrowsError(try Wire.decodeEvent(Data([0xA1, 0x00, 0x18, 0xC8]))) { error in
      XCTAssertEqual(error as? ProtocolError, .badOpcode(200))
    }
  }

  func testAddServiceArrayLengthMismatchRejected() {
    // A hand-built addService whose properties blob has fewer entries than the UUID array.
    var writer = CBORWriter()
    writer.mapHeader(7)
    writer.uint(0); writer.uint(14)
    writer.uint(7); writer.bytes(token)
    writer.uint(31); writer.text("180D")
    writer.uint(44); writer.bytes(Wire.packUInts([0x10])) // one property
    writer.uint(45); writer.bytes(Wire.packUInts([0x01, 0x02])) // two permissions
    writer.uint(46); writer.uint(1)
    writer.uint(51); writer.textArray(["2A37", "2A38"]) // two UUIDs
    XCTAssertThrowsError(try Wire.decodeRequest(writer.data)) { error in
      XCTAssertEqual(error as? ProtocolError, .malformed)
    }
  }

  // MARK: Framing

  func testFrameCarriesBigEndianLength() {
    XCTAssertEqual(Framing.frame(Data([0xDE, 0xAD, 0xBE, 0xEF])),
                   Data([0, 0, 0, 4, 0xDE, 0xAD, 0xBE, 0xEF]))
  }

  func testPayloadLengthParses() throws {
    XCTAssertEqual(try Framing.payloadLength(Data([0, 0, 1, 0])), 256)
  }

  func testOversizeFrameRejected() {
    XCTAssertThrowsError(try Framing.payloadLength(Data([0x00, 0x20, 0x00, 0x01]))) { error in
      XCTAssertEqual(error as? ProtocolError, .frameTooLarge(0x200001))
    }
  }

  // MARK: Byte-parity with the C codec

  // These are the exact bytes the C codec's protocol_test asserts for the same logical messages,
  // so the two codecs are each other's byte-for-byte oracle. A change to either side that drifts
  // the wire breaks both suites.

  func testHelloIdentityMatchesCBytes() {
    let want = Data([0xA5, 0x00, 0x01, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x08, 0x01, 0x0E, 0x61, 0x61, 0x18, 0x1C, 0x63, 0x41, 0x70, 0x70])
    XCTAssertEqual(Wire.encode(.hello(version: 1), token: token, appID: "a", displayName: "App"),
                   want)
  }

  func testCentralStateMatchesCBytes() {
    let want = Data([0xA2, 0x00, 0x02, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32))
    XCTAssertEqual(Wire.encode(.centralState, token: token), want)
  }

  func testScanStartFilterMatchesCBytes() {
    let want = Data([0xA3, 0x00, 0x03, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x32, 0x81, 0x64, 0x31, 0x38, 0x30, 0x44])
    XCTAssertEqual(Wire.encode(.scanStart(serviceUUIDs: ["180D"]), token: token), want)
  }

  func testConnectMatchesCBytes() {
    let want = Data([0xA3, 0x00, 0x05, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04])
    XCTAssertEqual(Wire.encode(.connect(peripheralId: pid), token: token), want)
  }

  func testDiscoverServicesMatchesCBytes() {
    let want = Data([0xA4, 0x00, 0x07, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04, 0x18, 0x32, 0x81, 0x64, 0x31, 0x38, 0x30, 0x44])
    XCTAssertEqual(Wire.encode(.discoverServices(peripheralId: pid, serviceUUIDs: ["180D"]),
                               token: token), want)
  }

  func testDiscoverCharacteristicsMatchesCBytes() {
    let want = Data([0xA5, 0x00, 0x08, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04, 0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44,
         0x18, 0x33, 0x81, 0x64, 0x32, 0x41, 0x33, 0x37])
    let payload = Wire.encode(.discoverCharacteristics(peripheralId: pid, serviceUUID: "180D",
                                                       characteristicUUIDs: ["2A37"]), token: token)
    XCTAssertEqual(payload, want)
  }

  func testDiscoverResponsesMatchCBytes() {
    let services = Data([0xA4, 0x00, 0x07, 0x01, 0x00, 0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04,
                         0x18, 0x32, 0x81, 0x64, 0x31, 0x38, 0x30, 0x44])
    XCTAssertEqual(Wire.encode(.servicesDiscovered(peripheralId: pid, serviceUUIDs: ["180D"])),
                   services)
    let chars = Data([0xA5, 0x00, 0x08, 0x01, 0x00, 0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04,
                      0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44, 0x18, 0x33, 0x81, 0x64, 0x32,
                      0x41, 0x33, 0x37])
    XCTAssertEqual(Wire.encode(.characteristicsDiscovered(peripheralId: pid, serviceUUID: "180D",
                                                          characteristicUUIDs: ["2A37"])), chars)
  }

  func testReadCharacteristicMatchesCBytes() {
    let want = Data([0xA5, 0x00, 0x09, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04, 0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44,
         0x18, 0x20, 0x64, 0x32, 0x41, 0x33, 0x37])
    let payload = Wire.encode(.readCharacteristic(peripheralId: pid, serviceUUID: "180D",
                                                  characteristicUUID: "2A37"), token: token)
    XCTAssertEqual(payload, want)
  }

  func testWriteCharacteristicMatchesCBytes() {
    let want = Data([0xA7, 0x00, 0x0A, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04, 0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44,
         0x18, 0x20, 0x64, 0x32, 0x41, 0x33, 0x37, 0x18, 0x21, 0x43, 0xDE, 0xAD, 0xBE, 0x18,
         0x27, 0x01])
    let payload = Wire.encode(.writeCharacteristic(peripheralId: pid, serviceUUID: "180D",
                                                   characteristicUUID: "2A37", value: val,
                                                   writeType: .withoutResponse), token: token)
    XCTAssertEqual(payload, want)
  }

  func testSetNotifyMatchesCBytes() {
    let want = Data([0xA6, 0x00, 0x0B, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04, 0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44,
         0x18, 0x20, 0x64, 0x32, 0x41, 0x33, 0x37, 0x18, 0x28, 0x01])
    let payload = Wire.encode(.setNotify(peripheralId: pid, serviceUUID: "180D",
                                         characteristicUUID: "2A37", enabled: true), token: token)
    XCTAssertEqual(payload, want)
  }

  func testRespondReadMatchesCBytes() {
    let want = Data([0xA5, 0x00, 0x12, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x21, 0x43, 0xDE, 0xAD, 0xBE, 0x18, 0x2A, 0x07, 0x18, 0x31, 0x00])
    XCTAssertEqual(Wire.encode(.respondRead(requestId: 7, value: val, attError: 0),
                               token: token), want)
  }

  func testRespondWriteMatchesCBytes() {
    let want = Data([0xA4, 0x00, 0x13, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x2A, 0x07, 0x18, 0x31, 0x00])
    XCTAssertEqual(Wire.encode(.respondWrite(requestId: 7, attError: 0), token: token), want)
  }

  func testAddServiceMatchesCBytes() {
    let want = Data([0xA7, 0x00, 0x0E, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44, 0x18, 0x2C, 0x52, 0x00, 0x02, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x18, 0x2D,
         0x52, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x02, 0x18, 0x2E, 0x01, 0x18, 0x33, 0x82, 0x64, 0x32, 0x41, 0x33, 0x37,
         0x64, 0x32, 0x41, 0x33, 0x38])
    let chars = [CharacteristicSpec(uuid: "2A37", properties: 0x10, permissions: 0x01),
                 CharacteristicSpec(uuid: "2A38", properties: 0x08, permissions: 0x02)]
    XCTAssertEqual(Wire.encode(.addService(serviceUUID: "180D", isPrimary: true,
                                           characteristics: chars), token: token), want)
  }

  func testRemoveServiceMatchesCBytes() {
    let want = Data([0xA3, 0x00, 0x0F, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44])
    XCTAssertEqual(Wire.encode(.removeService(serviceUUID: "180D"), token: token), want)
  }

  func testStartAdvertisingMatchesCBytes() {
    let want = Data([0xA4, 0x00, 0x10, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x23, 0x63, 0x44, 0x65, 0x76, 0x18, 0x24, 0x81, 0x64, 0x31, 0x38, 0x30, 0x44])
    XCTAssertEqual(Wire.encode(.startAdvertising(localName: "Dev", serviceUUIDs: ["180D"]),
                               token: token), want)
  }

  func testUpdateValueMatchesCBytes() {
    let want = Data([0xA6, 0x00, 0x14, 0x07, 0x58, 0x20] + [UInt8](repeating: 0xAB, count: 32)
      + [0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44, 0x18, 0x20, 0x64, 0x32, 0x41, 0x33, 0x37,
         0x18, 0x21, 0x43, 0xDE, 0xAD, 0xBE, 0x18, 0x2F, 0x42, 0x09, 0x08])
    XCTAssertEqual(Wire.encode(.updateValue(serviceUUID: "180D", characteristicUUID: "2A37",
                                            value: val, centralId: cid), token: token), want)
  }
}
