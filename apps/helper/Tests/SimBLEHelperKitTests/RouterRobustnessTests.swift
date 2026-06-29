// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHelperKit
import SimBLEHostCore
import SimBLEProtocol
import XCTest

/// The router is the helper's front door for hostile bytes from an injected app.
/// Whatever arrives, it answers with a failure and never crashes. None of these reach
/// the radio, so they run without one.
final class RouterRobustnessTests: XCTestCase {
  private func router(session: CapabilityToken) -> RequestRouter {
    RequestRouter(service: CentralService(backend: FakeCentralBackend()),
                  peripheralService: PeripheralService(backend: FakePeripheralBackend()),
                  gate: AuthGate(session: session))
  }

  func testHostilePayloadsYieldFailuresNotCrashes() {
    let router = router(session: CapabilityToken())
    let hostile: [(String, Data)] = [
      ("empty", Data()),
      ("not cbor", Data([0xFF, 0xFF, 0xFF, 0xFF])),
      ("truncated map", Data([0xA1, 0x00])),
      ("text-header run", Data(repeating: 0x61, count: 64)),
    ]
    for (name, payload) in hostile {
      guard case .failure = router.respond(toPayload: payload) else {
        return XCTFail("hostile payload '\(name)' must yield a failure")
      }
    }
  }

  func testValidTokenWithUnknownOpFailsCleanly() {
    // The right token but op 99: it passes the gate, then the decoder rejects the op,
    // so the helper returns a failure rather than crashing or misdispatching.
    let session = CapabilityToken()
    var payload = Data([0xA2, 0x00, 0x18, 0x63, 0x07, 0x58, 0x20])
    payload.append(session.bytes)
    guard case let .failure(_, code, _) = router(session: session).respond(toPayload: payload)
    else {
      return XCTFail("an unknown op must come back as a failure")
    }
    XCTAssertEqual(code, BridgeErrorCode.malformed)
  }

  func testDuplicateKeyIsRejected() {
    // Two key-0 entries in one map: { 0: 2, 0: 2, 7: <token> }. The codec requires one
    // value per key, so the decode (after the gate) rejects it.
    let session = CapabilityToken()
    var payload = Data([0xA3, 0x00, 0x02, 0x00, 0x02, 0x07, 0x58, 0x20])
    payload.append(session.bytes)
    guard case let .failure(_, code, _) = router(session: session).respond(toPayload: payload)
    else {
      return XCTFail("a duplicate key must come back as a failure")
    }
    XCTAssertEqual(code, BridgeErrorCode.unauthorized,
                   "a duplicate key makes the token field ambiguous, so the gate rejects first")
  }

  func testOversizedFrameLengthIsRefused() {
    // A length prefix past the 1 MiB cap must be refused without allocating that much.
    let oversized = Framing.maxFrame + 1
    let prefix = Data([
      UInt8((oversized >> 24) & 0xFF), UInt8((oversized >> 16) & 0xFF),
      UInt8((oversized >> 8) & 0xFF), UInt8(oversized & 0xFF),
    ])
    XCTAssertThrowsError(try Framing.payloadLength(prefix)) { error in
      guard case ProtocolError.frameTooLarge = error else {
        return XCTFail("an oversized frame must be refused as frameTooLarge, got \(error)")
      }
    }
  }
}
