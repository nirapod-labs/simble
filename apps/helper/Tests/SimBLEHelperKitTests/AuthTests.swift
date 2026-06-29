// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHelperKit
import SimBLEHostCore
import SimBLEProtocol
import XCTest

/// The token, the gate, and the router's token-before-op rule: a bad, short, or
/// missing token is rejected before the op is interpreted. None of these need a radio.
final class AuthTests: XCTestCase {
  // MARK: token

  func testMintIs32Bytes() {
    XCTAssertEqual(CapabilityToken().bytes.count, 32)
  }

  func testTwoMintsDiffer() {
    XCTAssertNotEqual(CapabilityToken().bytes, CapabilityToken().bytes)
  }

  func testHexRoundTrips() {
    let token = CapabilityToken()
    XCTAssertEqual(token.hex.count, 64)
    XCTAssertEqual(CapabilityToken(hex: token.hex), token)
  }

  func testHexRejectsBadInput() {
    XCTAssertNil(CapabilityToken(hex: "xyz"))
    XCTAssertNil(CapabilityToken(hex: String(repeating: "0", count: 63)))
    XCTAssertNil(CapabilityToken(hex: String(repeating: "g", count: 64)))
  }

  func testBytesRejectsWrongLength() {
    XCTAssertNil(CapabilityToken(bytes: Data(repeating: 0, count: 31)))
  }

  // MARK: gate

  func testGateAcceptsSameRejectsDifferent() throws {
    let token = CapabilityToken()
    let gate = AuthGate(session: token)
    XCTAssertTrue(try gate.accepts(XCTUnwrap(CapabilityToken(bytes: token.bytes))))
    var flipped = Data(token.bytes)
    flipped[flipped.startIndex] ^= 0x01
    XCTAssertFalse(try gate.accepts(XCTUnwrap(CapabilityToken(bytes: flipped))))
    var lastFlipped = Data(token.bytes)
    lastFlipped[lastFlipped.index(before: lastFlipped.endIndex)] ^= 0x80
    XCTAssertFalse(try gate.accepts(XCTUnwrap(CapabilityToken(bytes: lastFlipped))))
  }

  // MARK: router enforces token before op

  private func router(session: CapabilityToken) -> RequestRouter {
    RequestRouter(service: CentralService(backend: FakeCentralBackend()),
                  peripheralService: PeripheralService(backend: FakePeripheralBackend()),
                  gate: AuthGate(session: session))
  }

  func testWrongTokenIsRejectedBeforeTheOp() {
    let session = CapabilityToken()
    let payload = Wire.encode(.centralState, token: CapabilityToken().bytes)
    guard case let .failure(_, code, _) = router(session: session).respond(toPayload: payload)
    else {
      return XCTFail("a wrong token must fail")
    }
    XCTAssertEqual(code, BridgeErrorCode.unauthorized)
  }

  func testShortTokenIsRejected() {
    // A hand-built request with a 16-byte token in key 7: { 0: 2, 7: <16 bytes> }.
    let session = CapabilityToken()
    var payload = Data([0xA2, 0x00, 0x02, 0x07, 0x50])
    payload.append(Data(repeating: 0xAB, count: 16))
    guard case let .failure(_, code, _) = router(session: session).respond(toPayload: payload)
    else {
      return XCTFail("a short token must fail")
    }
    XCTAssertEqual(code, BridgeErrorCode.unauthorized)
  }

  func testMissingTokenIsRejected() {
    // A request with no key 7 at all: { 0: 2 }.
    let session = CapabilityToken()
    let payload = Data([0xA1, 0x00, 0x02])
    guard case let .failure(_, code, _) = router(session: session).respond(toPayload: payload)
    else {
      return XCTFail("a missing token must fail")
    }
    XCTAssertEqual(code, BridgeErrorCode.unauthorized)
  }

  func testAuthFailureDoesNotReachTheBackend() {
    // The right gate but a wrong token: the op is never interpreted, so a backend that
    // would crash on use is never touched. A central-state op is chosen; the failure is the
    // auth failure, not a state read.
    let session = CapabilityToken()
    let payload = Wire.encode(.scanStart(serviceUUIDs: nil), token: CapabilityToken().bytes)
    guard case let .failure(op, code, _) = router(session: session).respond(toPayload: payload)
    else {
      return XCTFail("a wrong token must fail")
    }
    XCTAssertEqual(code, BridgeErrorCode.unauthorized)
    XCTAssertEqual(op, 0, "an auth failure echoes no op, so the op surface is not revealed")
  }
}
