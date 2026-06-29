// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
@testable import SimBLEHostCore
import XCTest

/// A push to a peripheral-created `CBMutableCharacteristic` can arrive with no service named,
/// because that characteristic carries no service back-reference. The resolver must still find
/// the characteristic by scanning the published services, and return nil for an unknown one.
final class CharacteristicResolverTests: XCTestCase {
  private let serviceUUID = "F000AA00-0451-4000-B000-000000000000"
  private let charUUID = "F000AA01-0451-4000-B000-000000000000"

  private func published() -> [String: CBMutableService] {
    let characteristic = CBMutableCharacteristic(
      type: CBUUID(string: charUUID), properties: [.read, .notify], value: nil,
      permissions: [.readable]
    )
    let service = CBMutableService(type: CBUUID(string: serviceUUID), primary: true)
    service.characteristics = [characteristic]
    return [serviceUUID: service]
  }

  func testResolvesWhenServiceIsNamed() {
    let found = CoreBluetoothPeripheral.resolveCharacteristic(
      charUUID, serviceUUID: serviceUUID, in: published()
    )
    XCTAssertEqual(found?.uuid, CBUUID(string: charUUID))
  }

  func testResolvesWhenServiceIsUnnamed() {
    let found = CoreBluetoothPeripheral.resolveCharacteristic(
      charUUID, serviceUUID: "", in: published()
    )
    XCTAssertEqual(found?.uuid, CBUUID(string: charUUID))
  }

  func testReturnsNilForUnknownCharacteristic() {
    XCTAssertNil(CoreBluetoothPeripheral.resolveCharacteristic(
      "2A37", serviceUUID: "", in: published()
    ))
  }
}
