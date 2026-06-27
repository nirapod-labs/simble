// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import Foundation
@testable import SimBLEHostCore
import SimBLEProtocol
import XCTest

/// These exercise the real `CBCentralManager`. Instantiating one without a granted
/// Bluetooth authorization aborts the process (no usage-description in a bare test
/// bundle), so they skip unless authorization is already `allowedAlways`, then wait
/// for `poweredOn` and skip on timeout. They run only from a properly bundled host;
/// on a radio-less runner and on a Mac regardless of Bluetooth state they skip, so
/// the suite is green everywhere. The fake-backend tests carry the deterministic
/// dispatch coverage.
final class CoreBluetoothCentralTests: XCTestCase {
  /// How long to wait for the manager to power on before skipping.
  private static let powerOnTimeout: TimeInterval = 3

  /// Build the driver and wait for `poweredOn`, or skip. Authorization short of
  /// `allowedAlways` skips before any manager is constructed, which is the only safe
  /// path: constructing one without authorization aborts.
  private func poweredOnCentral() throws -> CoreBluetoothCentral {
    try XCTSkipUnless(CBManager.authorization == .allowedAlways,
                      "Bluetooth not authorized for this process (run from the bundled host)")
    let central = CoreBluetoothCentral()
    let deadline = Date().addingTimeInterval(Self.powerOnTimeout)
    while Date() < deadline {
      if central.managerState() == Wire.managerStatePoweredOn { return central }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw XCTSkip("Bluetooth central not powered on (off, or unsupported)")
  }

  func testManagerReachesPoweredOnOrSkips() throws {
    let central = try poweredOnCentral()
    XCTAssertEqual(central.managerState(), Wire.managerStatePoweredOn)
  }

  func testHostStatusReportsCentralSupportedWhenPoweredOn() throws {
    let central = try poweredOnCentral()
    let status = CentralService(backend: central).hostStatus()
    XCTAssertTrue(status.centralSupported)
    XCTAssertEqual(status.centralState, Wire.managerStatePoweredOn)
  }

  func testUnknownPeripheralFailsCleanly() throws {
    let central = try poweredOnCentral()
    // A connect to an id the manager never surfaced fails with the device code, not a crash.
    XCTAssertThrowsError(try central.connect(peripheralId: Data([0, 1, 2, 3]))) { error in
      guard error is CentralBackendError else {
        return XCTFail("expected a CentralBackendError, got \(error)")
      }
    }
  }

  func testScanStartAndStopDoNotThrowWhenPoweredOn() throws {
    let central = try poweredOnCentral()
    XCTAssertNoThrow(try central.startScan(serviceUUIDs: nil))
    XCTAssertNoThrow(try central.stopScan())
  }
}
