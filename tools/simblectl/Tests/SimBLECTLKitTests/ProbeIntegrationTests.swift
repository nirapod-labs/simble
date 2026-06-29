// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLECTLKit
import SimBLEHelperKit
import SimBLEHostCore
import SimBLEProtocol
import XCTest

/// The real prober driven against a live in-process listener, with no radio: it negotiates
/// the version over HELLO, and a wrong token reports no bridge.
final class ProbeIntegrationTests: XCTestCase {
  /// A radio-free `CentralBackend`. The HELLO path never reaches it; the listener needs one
  /// to build the router.
  private final class StubCentralBackend: CentralBackend, @unchecked Sendable {
    func setEventSink(_: @escaping @Sendable (CentralBackendEvent) -> Void) {}
    func managerState() -> UInt64 { Wire.managerStatePoweredOn }
    func startScan(serviceUUIDs _: [String]?) throws {}
    func stopScan() throws {}
    func connect(peripheralId _: Data) throws {}
    func disconnect(peripheralId _: Data) throws {}
    func discoverServices(peripheralId _: Data, serviceUUIDs _: [String]?) throws -> [String] { [] }
    func discoverCharacteristics(peripheralId _: Data, serviceUUID _: String,
                                 characteristicUUIDs _: [String]?) throws -> [String] { [] }
    func readCharacteristic(peripheralId _: Data, serviceUUID _: String,
                            characteristicUUID _: String) throws -> Data { Data() }
    func writeCharacteristic(peripheralId _: Data, serviceUUID _: String,
                             characteristicUUID _: String, value _: Data,
                             withResponse _: Bool) throws {}
    func setNotify(peripheralId _: Data, serviceUUID _: String, characteristicUUID _: String,
                   enabled _: Bool) throws -> Bool { false }
    func readRSSI(peripheralId _: Data) throws -> Int64 { 0 }
    func peripheralState(peripheralId _: Data) throws -> UInt64 { 0 }
  }

  /// A radio-free `PeripheralBackend`, for the same reason.
  private final class StubPeripheralBackend: PeripheralBackend, @unchecked Sendable {
    func setEventSink(_: @escaping @Sendable (PeripheralBackendEvent) -> Void) {}
    func managerState() -> UInt64 { Wire.managerStatePoweredOn }
    func addService(serviceUUID _: String, isPrimary _: Bool,
                    characteristics _: [CharacteristicSpec]) throws {}
    func removeService(serviceUUID _: String) throws {}
    func startAdvertising(localName _: String?, serviceUUIDs _: [String]?) throws {}
    func stopAdvertising() throws {}
    func respondRead(requestId _: UInt64, value _: Data, attError _: UInt64) throws {}
    func respondWrite(requestId _: UInt64, attError _: UInt64) throws {}
    func updateValue(serviceUUID _: String, characteristicUUID _: String, value _: Data,
                     centralId _: Data?) throws {}
  }

  private func startListener(token: CapabilityToken) throws -> LoopbackListener {
    let listener = LoopbackListener(
      router: RequestRouter(service: CentralService(backend: StubCentralBackend()),
                            peripheralService: PeripheralService(backend: StubPeripheralBackend()),
                            gate: AuthGate(session: token))
    )
    try listener.start()
    return listener
  }

  func testProbeReachesALiveListener() throws {
    let token = CapabilityToken()
    let listener = try startListener(token: token)
    defer { listener.stop() }
    let probe = SimBLECTL.probeBridge(HelperState(port: listener.port, token: token.hex))
    XCTAssertEqual(probe?.protocolVersion, UInt64(SimBLEProtocol.version))
  }

  func testProbeWithAWrongTokenReportsNoBridge() throws {
    let listener = try startListener(token: CapabilityToken())
    defer { listener.stop() }
    let probe = SimBLECTL.probeBridge(HelperState(port: listener.port, token: CapabilityToken().hex))
    XCTAssertNil(probe)
  }
}
