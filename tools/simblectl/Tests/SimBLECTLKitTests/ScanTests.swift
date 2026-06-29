// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLECTLKit
import SimBLEHelperKit
import SimBLEHostCore
import SimBLEProtocol
import XCTest

/// The `scan` verb through its scanner seam, and the real `runScan` against a live in-process
/// listener with no radio.
final class ScanTests: XCTestCase {
  private let record = HelperState(port: 51234, token: String(repeating: "ab", count: 32))

  func testScanRendersDiscoveredDevicesInOrderWithOptionalFields() {
    let devices = [
      DiscoveredDevice(peripheralId: "0a1b", rssi: -77),
      DiscoveredDevice(peripheralId: "ff01", rssi: -42, localName: "Sensor",
                       serviceUUIDs: ["180D", "180F"]),
    ]
    let result = SimBLECTL.handle(
      arguments: ["simblectl", "scan"], state: { self.record }, scan: { _, _ in devices }
    )
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(
      result.output,
      #"{"discovered":[{"peripheralId":"0a1b","rssi":-77},"#
        + #"{"peripheralId":"ff01","rssi":-42,"localName":"Sensor","serviceUUIDs":["180D","180F"]}]}"#
    )
  }

  func testScanWithNoRecordReportsNoRunningHelper() {
    let result = SimBLECTL.handle(
      arguments: ["simblectl", "scan"], state: { nil }, scan: { _, _ in [] }
    )
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertEqual(result.output, #"{"error":"no running helper"}"#)
  }

  /// A radio-free `CentralBackend` that re-emits one discovery through its sink every 10ms
  /// while scanning, dispatched on a background queue.
  private final class DiscoveringCentralBackend: CentralBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (CentralBackendEvent) -> Void)?
    private var scanning = false
    private let discovery: CentralBackendEvent

    init(discovery: CentralBackendEvent) {
      self.discovery = discovery
    }

    func setEventSink(_ sink: @escaping @Sendable (CentralBackendEvent) -> Void) {
      lock.lock(); self.sink = sink; lock.unlock()
    }

    func startScan(serviceUUIDs _: [String]?) throws {
      lock.lock(); scanning = true; lock.unlock()
      emitRepeatedly()
    }

    private func emitRepeatedly() {
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [weak self] in
        guard let self else { return }
        lock.lock(); let active = scanning; let sink = self.sink; lock.unlock()
        guard active else { return }
        sink?(discovery)
        emitRepeatedly()
      }
    }

    func managerState() -> UInt64 { Wire.managerStatePoweredOn }
    func stopScan() throws { lock.lock(); scanning = false; lock.unlock() }
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

  /// A radio-free `PeripheralBackend`; the listener needs one to build the router.
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

  func testRealRunScanCollectsADiscoveryFromALiveListener() throws {
    let token = CapabilityToken()
    let peripheralId = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let backend = DiscoveringCentralBackend(discovery: .discovered(
      peripheralId: peripheralId, localName: "Sensor", serviceUUIDs: ["180D"],
      txPower: nil, manufacturerData: nil, rssi: -40
    ))
    let listener = LoopbackListener(
      router: RequestRouter(service: CentralService(backend: backend),
                            peripheralService: PeripheralService(backend: StubPeripheralBackend()),
                            gate: AuthGate(session: token))
    )
    try listener.start()
    defer { listener.stop() }

    let devices = SimBLECTL.runScan(HelperState(port: listener.port, token: token.hex), 0.5)
    XCTAssertEqual(devices, [DiscoveredDevice(peripheralId: "deadbeef", rssi: -40,
                                              localName: "Sensor", serviceUUIDs: ["180D"])])
  }
}
