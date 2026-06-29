// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import Foundation
@testable import SimBLEHostCore
import SimBLEProtocol
import XCTest

/// These exercise the real `CBPeripheralManager`. Instantiating one without a granted
/// Bluetooth authorization aborts the process (no usage-description in a bare test
/// bundle), so they skip unless authorization is already `allowedAlways`, then wait
/// for `poweredOn` and skip on timeout. They run only from a properly bundled host;
/// on a radio-less runner and on a Mac regardless of Bluetooth state they skip, so
/// the suite is green everywhere. The fake-backend tests carry the deterministic
/// dispatch coverage.
final class CoreBluetoothPeripheralTests: XCTestCase {
  /// How long to wait for the manager to power on before skipping.
  private static let powerOnTimeout: TimeInterval = 3
  private let serviceUUID = "180D"
  private let charUUID = "2A37"

  /// Build the driver and wait for `poweredOn`, or skip. Authorization short of
  /// `allowedAlways` skips before any manager is constructed, which is the only safe
  /// path: constructing one without authorization aborts.
  private func poweredOnPeripheral() throws -> CoreBluetoothPeripheral {
    try XCTSkipUnless(CBManager.authorization == .allowedAlways,
                      "Bluetooth not authorized for this process (run from the bundled host)")
    let peripheral = CoreBluetoothPeripheral()
    let deadline = Date().addingTimeInterval(Self.powerOnTimeout)
    while Date() < deadline {
      if peripheral.managerState() == Wire.managerStatePoweredOn { return peripheral }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw XCTSkip("Bluetooth peripheral not powered on (off, or unsupported)")
  }

  func testManagerReachesPoweredOnOrSkips() throws {
    let peripheral = try poweredOnPeripheral()
    XCTAssertEqual(peripheral.managerState(), Wire.managerStatePoweredOn)
  }

  func testAddServiceDoesNotThrowWhenPoweredOn() throws {
    let peripheral = try poweredOnPeripheral()
    let spec = CharacteristicSpec(uuid: charUUID, properties: 0x12, permissions: 0x01)
    XCTAssertNoThrow(try peripheral.addService(serviceUUID: serviceUUID, isPrimary: true,
                                               characteristics: [spec]))
  }

  func testUpdateValueOnUnknownServiceFailsCleanly() throws {
    let peripheral = try poweredOnPeripheral()
    // An update to a service the manager never published fails with the device code, not a crash.
    XCTAssertThrowsError(try peripheral.updateValue(serviceUUID: serviceUUID,
                                                    characteristicUUID: charUUID,
                                                    value: Data([0x01]), centralId: nil))
    { error in
      guard error is PeripheralBackendError else {
        return XCTFail("expected a PeripheralBackendError, got \(error)")
      }
    }
  }

  func testRespondToUnknownRequestFailsCleanly() throws {
    let peripheral = try poweredOnPeripheral()
    XCTAssertThrowsError(try peripheral.respondWrite(requestId: 999, attError: 0)) { error in
      guard error is PeripheralBackendError else {
        return XCTFail("expected a PeripheralBackendError, got \(error)")
      }
    }
  }

  func testStartAdvertisingTwiceSucceeds() throws {
    let peripheral = try poweredOnPeripheral()
    XCTAssertNoThrow(try peripheral.startAdvertising(localName: "SimBLE", serviceUUIDs: nil))
    // A repeat advertise replaces the live one rather than failing as already-advertising.
    XCTAssertNoThrow(try peripheral.startAdvertising(localName: "SimBLE", serviceUUIDs: nil))
  }

  func testReAddingTheSameServiceSucceeds() throws {
    let peripheral = try poweredOnPeripheral()
    let spec = CharacteristicSpec(uuid: charUUID, properties: 0x12, permissions: 0x01)
    XCTAssertNoThrow(try peripheral.addService(serviceUUID: serviceUUID, isPrimary: true,
                                               characteristics: [spec]))
    // A re-add replaces the prior registration rather than leaving a duplicate service.
    XCTAssertNoThrow(try peripheral.addService(serviceUUID: serviceUUID, isPrimary: true,
                                               characteristics: [spec]))
  }
}
