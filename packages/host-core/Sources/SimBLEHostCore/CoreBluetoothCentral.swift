// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import Foundation

/// The real central driver: a `CBCentralManager` and `CBPeripheralDelegate` behind
/// the `CentralBackend` surface. Each command blocks the calling thread on a latch
/// until its delegate callback fires or a deadline passes; unsolicited results (a
/// scan hit, a notification, an unexpected disconnect, a state change) go to the
/// event sink.
///
/// The bridge moves GATT traffic only. No pairing secret or key material is read,
/// stored, or relayed by this driver.
public final class CoreBluetoothCentral: NSObject, CentralBackend, @unchecked Sendable {
  /// How long a command waits for its delegate callback before reporting a timeout.
  private static let commandTimeout: TimeInterval = 10

  private let queue = DispatchQueue(label: "simble.central")
  private var manager: CBCentralManager!
  private let lock = NSLock()

  /// Peripherals the manager has surfaced, keyed by identifier bytes; populated by a scan hit.
  private var peripherals: [Data: CBPeripheral] = [:]
  // Pending command latches keyed by a discriminator, signaled by the delegate callback.
  private var serviceWaiters: [Data: Latch<[String]>] = [:]
  private var characteristicWaiters: [CharKey: Latch<[String]>] = [:]
  private var readWaiters: [CharKey: Latch<Data>] = [:]
  private var notifyWaiters: [CharKey: Latch<Bool>] = [:]
  private var rssiWaiters: [Data: Latch<Int64>] = [:]
  private var eventSink: (@Sendable (CentralBackendEvent) -> Void)?

  /// Build the driver and start the manager on its own queue. The manager reaches
  /// `poweredOn` asynchronously; `managerState()` observes it.
  override public init() {
    super.init()
    manager = CBCentralManager(delegate: self, queue: queue)
  }

  public func setEventSink(_ sink: @escaping @Sendable (CentralBackendEvent) -> Void) {
    lock.lock()
    eventSink = sink
    lock.unlock()
  }

  public func managerState() -> UInt64 {
    UInt64(max(0, manager.state.rawValue))
  }

  public func startScan(serviceUUIDs: [String]?) throws {
    let services = serviceUUIDs?.map { CBUUID(string: $0) }
    queue.async { self.manager.scanForPeripherals(withServices: services, options: nil) }
  }

  public func stopScan() throws {
    queue.async { self.manager.stopScan() }
  }

  public func connect(peripheralId: Data) throws {
    let peripheral = try lookup(peripheralId)
    // Real connect never blocks and has no timeout. This returns once the request is issued;
    // didConnect or didFailToConnect emits the outcome as an event.
    queue.async { self.manager.connect(peripheral, options: nil) }
  }

  public func disconnect(peripheralId: Data) throws {
    let peripheral = try lookup(peripheralId)
    queue.async { self.manager.cancelPeripheralConnection(peripheral) }
  }

  public func discoverServices(peripheralId: Data, serviceUUIDs: [String]?) throws -> [String] {
    let peripheral = try lookup(peripheralId)
    let latch = Latch<[String]>()
    setServiceWaiter(latch, for: peripheralId)
    let services = serviceUUIDs?.map { CBUUID(string: $0) }
    queue.async { peripheral.discoverServices(services) }
    return try wait(latch) { self.clearServiceWaiter(peripheralId) }
  }

  public func discoverCharacteristics(peripheralId: Data, serviceUUID: String,
                                      characteristicUUIDs: [String]?) throws -> [String]
  {
    let peripheral = try lookup(peripheralId)
    guard let service = service(serviceUUID, on: peripheral) else {
      throw CentralBackendError(code: Self.unknownAttribute, message: "service not discovered")
    }
    let key = CharKey(peripheralId: peripheralId, serviceUUID: serviceUUID,
                      characteristicUUID: "")
    let latch = Latch<[String]>()
    setCharacteristicWaiter(latch, for: key)
    let uuids = characteristicUUIDs?.map { CBUUID(string: $0) }
    queue.async { peripheral.discoverCharacteristics(uuids, for: service) }
    return try wait(latch) { self.clearCharacteristicWaiter(key) }
  }

  public func readCharacteristic(peripheralId: Data, serviceUUID: String,
                                 characteristicUUID: String) throws -> Data
  {
    let peripheral = try lookup(peripheralId)
    guard let characteristic = characteristic(characteristicUUID, serviceUUID: serviceUUID,
                                              on: peripheral)
    else {
      throw CentralBackendError(
        code: Self.unknownAttribute,
        message: "characteristic not discovered"
      )
    }
    let key = CharKey(peripheralId: peripheralId, serviceUUID: serviceUUID,
                      characteristicUUID: characteristicUUID)
    let latch = Latch<Data>()
    setReadWaiter(latch, for: key)
    queue.async { peripheral.readValue(for: characteristic) }
    return try wait(latch) { self.clearReadWaiter(key) }
  }

  public func writeCharacteristic(peripheralId: Data, serviceUUID: String,
                                  characteristicUUID: String, value: Data,
                                  withResponse: Bool) throws
  {
    let peripheral = try lookup(peripheralId)
    guard let characteristic = characteristic(characteristicUUID, serviceUUID: serviceUUID,
                                              on: peripheral)
    else {
      throw CentralBackendError(
        code: Self.unknownAttribute,
        message: "characteristic not discovered"
      )
    }
    let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
    queue.async { peripheral.writeValue(value, for: characteristic, type: type) }
  }

  public func setNotify(peripheralId: Data, serviceUUID: String, characteristicUUID: String,
                        enabled: Bool) throws -> Bool
  {
    let peripheral = try lookup(peripheralId)
    guard let characteristic = characteristic(characteristicUUID, serviceUUID: serviceUUID,
                                              on: peripheral)
    else {
      throw CentralBackendError(
        code: Self.unknownAttribute,
        message: "characteristic not discovered"
      )
    }
    let key = CharKey(peripheralId: peripheralId, serviceUUID: serviceUUID,
                      characteristicUUID: characteristicUUID)
    let latch = Latch<Bool>()
    setNotifyWaiter(latch, for: key)
    queue.async { peripheral.setNotifyValue(enabled, for: characteristic) }
    return try wait(latch) { self.clearNotifyWaiter(key) }
  }

  public func readRSSI(peripheralId: Data) throws -> Int64 {
    let peripheral = try lookup(peripheralId)
    let latch = Latch<Int64>()
    setRSSIWaiter(latch, for: peripheralId)
    queue.async { peripheral.readRSSI() }
    return try wait(latch) { self.clearRSSIWaiter(peripheralId) }
  }

  public func peripheralState(peripheralId: Data) throws -> UInt64 {
    let peripheral = try lookup(peripheralId)
    return UInt64(max(0, peripheral.state.rawValue))
  }

  // MARK: lookup

  private func lookup(_ peripheralId: Data) throws -> CBPeripheral {
    lock.lock()
    let peripheral = peripherals[peripheralId]
    lock.unlock()
    guard let peripheral else {
      throw CentralBackendError(code: Self.unknownPeripheral, message: "unknown peripheral")
    }
    return peripheral
  }

  private func service(_ uuid: String, on peripheral: CBPeripheral) -> CBService? {
    let target = CBUUID(string: uuid)
    return peripheral.services?.first { $0.uuid == target }
  }

  private func characteristic(_ uuid: String, serviceUUID: String,
                              on peripheral: CBPeripheral) -> CBCharacteristic?
  {
    guard let service = service(serviceUUID, on: peripheral) else { return nil }
    let target = CBUUID(string: uuid)
    return service.characteristics?.first { $0.uuid == target }
  }

  private static func identifier(of peripheral: CBPeripheral) -> Data {
    withUnsafeBytes(of: peripheral.identifier.uuid) { Data($0) }
  }

  // MARK: latch bookkeeping

  private func wait<T>(_ latch: Latch<T>, cleanup: () -> Void) throws -> T {
    defer { cleanup() }
    guard let outcome = latch.wait(timeout: Self.commandTimeout) else {
      throw CentralBackendError(code: Self.timeout, message: "command timed out")
    }
    return try outcome.get()
  }

  private func emit(_ event: CentralBackendEvent) {
    lock.lock()
    let sink = eventSink
    lock.unlock()
    sink?(event)
  }
}

/// A one-shot result latch a command thread blocks on until a delegate callback fills it.
final class Latch<T>: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var result: Result<T, Error>?

  /// Store the first outcome and wake any waiter. A second call is ignored.
  func fulfill(_ value: Result<T, Error>) {
    lock.lock()
    if result == nil {
      result = value
      semaphore.signal()
    }
    lock.unlock()
  }

  /// Block until fulfilled, or return nil at the deadline.
  func wait(timeout: TimeInterval) -> Result<T, Error>? {
    guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}

/// A peripheral, service, and characteristic triple keying a per-characteristic latch.
struct CharKey: Hashable {
  let peripheralId: Data
  let serviceUUID: String
  let characteristicUUID: String
}

private extension CoreBluetoothCentral {
  static let unknownPeripheral: Int64 = 3 // CBError.peripheralDisconnected stand-in for unknown id
  static let unknownAttribute: Int64 = 4 // CBATTError.attributeNotFound
  static let timeout: Int64 = 9 // CBError.connectionTimeout
  static let opFailed: Int64 = 1 // CBError.unknown

  func setServiceWaiter(_ latch: Latch<[String]>, for id: Data) {
    lock.lock(); serviceWaiters[id] = latch; lock.unlock()
  }

  func clearServiceWaiter(_ id: Data) {
    lock.lock(); serviceWaiters[id] = nil; lock.unlock()
  }

  func setCharacteristicWaiter(_ latch: Latch<[String]>, for key: CharKey) {
    lock.lock(); characteristicWaiters[key] = latch; lock.unlock()
  }

  func clearCharacteristicWaiter(_ key: CharKey) {
    lock.lock(); characteristicWaiters[key] = nil; lock.unlock()
  }

  func setReadWaiter(_ latch: Latch<Data>, for key: CharKey) {
    lock.lock(); readWaiters[key] = latch; lock.unlock()
  }

  func clearReadWaiter(_ key: CharKey) {
    lock.lock(); readWaiters[key] = nil; lock.unlock()
  }

  func setNotifyWaiter(_ latch: Latch<Bool>, for key: CharKey) {
    lock.lock(); notifyWaiters[key] = latch; lock.unlock()
  }

  func clearNotifyWaiter(_ key: CharKey) {
    lock.lock(); notifyWaiters[key] = nil; lock.unlock()
  }

  func setRSSIWaiter(_ latch: Latch<Int64>, for id: Data) {
    lock.lock(); rssiWaiters[id] = latch; lock.unlock()
  }

  func clearRSSIWaiter(_ id: Data) {
    lock.lock(); rssiWaiters[id] = nil; lock.unlock()
  }
}

// MARK: CBCentralManagerDelegate

extension CoreBluetoothCentral: CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    emit(.stateChanged(state: UInt64(max(0, central.state.rawValue))))
  }

  public func centralManager(_: CBCentralManager, didDiscover peripheral: CBPeripheral,
                             advertisementData: [String: Any], rssi RSSI: NSNumber)
  {
    let id = Self.identifier(of: peripheral)
    lock.lock()
    peripherals[id] = peripheral
    lock.unlock()
    peripheral.delegate = self
    let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
      .map(\.uuidString)
    emit(.discovered(
      peripheralId: id,
      localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
      serviceUUIDs: serviceUUIDs,
      txPower: (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.int64Value,
      manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
      rssi: RSSI.int64Value
    ))
  }

  public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.delegate = self
    emit(.peripheralConnected(peripheralId: Self.identifier(of: peripheral)))
  }

  public func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                             error: Error?)
  {
    emit(.peripheralConnectFailed(peripheralId: Self.identifier(of: peripheral),
                                  errorCode: error.map { Int64(($0 as NSError).code) }))
  }

  public func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                             error: Error?)
  {
    emit(.peripheralDisconnected(peripheralId: Self.identifier(of: peripheral),
                                 errorCode: error.map { Int64(($0 as NSError).code) }))
  }
}

// MARK: CBPeripheralDelegate

extension CoreBluetoothCentral: CBPeripheralDelegate {
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let id = Self.identifier(of: peripheral)
    if let error {
      fulfillServices(id, .failure(Self.backendError(error, fallback: "discover services failed")))
      return
    }
    fulfillServices(id, .success((peripheral.services ?? []).map(\.uuid.uuidString)))
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    let key = CharKey(peripheralId: Self.identifier(of: peripheral),
                      serviceUUID: service.uuid.uuidString, characteristicUUID: "")
    if let error {
      fulfillCharacteristics(
        key, .failure(Self.backendError(error, fallback: "discover characteristics failed"))
      )
      return
    }
    fulfillCharacteristics(key, .success((service.characteristics ?? []).map(\.uuid.uuidString)))
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    let id = Self.identifier(of: peripheral)
    let serviceUUID = characteristic.service?.uuid.uuidString ?? ""
    let key = CharKey(peripheralId: id, serviceUUID: serviceUUID,
                      characteristicUUID: characteristic.uuid.uuidString)
    let value = characteristic.value ?? Data()
    // A pending read latch consumes the value; absent one, this is a subscription
    // notification and goes to the event sink.
    lock.lock()
    let waiter = readWaiters[key]
    lock.unlock()
    if let waiter {
      if let error {
        waiter.fulfill(.failure(Self.backendError(error, fallback: "read failed")))
      } else {
        waiter.fulfill(.success(value))
      }
      return
    }
    guard error == nil else { return }
    emit(.characteristicValue(peripheralId: id, serviceUUID: serviceUUID,
                              characteristicUUID: characteristic.uuid.uuidString, value: value))
  }

  public func peripheral(_ peripheral: CBPeripheral,
                         didUpdateNotificationStateFor characteristic: CBCharacteristic,
                         error: Error?)
  {
    let key = CharKey(peripheralId: Self.identifier(of: peripheral),
                      serviceUUID: characteristic.service?.uuid.uuidString ?? "",
                      characteristicUUID: characteristic.uuid.uuidString)
    if let error {
      fulfillNotify(key, .failure(Self.backendError(error, fallback: "set notify failed")))
      return
    }
    fulfillNotify(key, .success(characteristic.isNotifying))
  }

  public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    let id = Self.identifier(of: peripheral)
    if let error {
      fulfillRSSI(id, .failure(Self.backendError(error, fallback: "read rssi failed")))
      return
    }
    fulfillRSSI(id, .success(RSSI.int64Value))
  }
}

private extension CoreBluetoothCentral {
  static func backendError(_ error: Error?, fallback: String) -> CentralBackendError {
    guard let error = error as NSError? else {
      return CentralBackendError(code: opFailed, message: fallback)
    }
    return CentralBackendError(code: Int64(error.code), message: error.localizedDescription)
  }

  func fulfillServices(_ id: Data, _ result: Result<[String], Error>) {
    lock.lock(); let latch = serviceWaiters[id]; lock.unlock()
    latch?.fulfill(result)
  }

  func fulfillCharacteristics(_ key: CharKey, _ result: Result<[String], Error>) {
    lock.lock(); let latch = characteristicWaiters[key]; lock.unlock()
    latch?.fulfill(result)
  }

  func fulfillNotify(_ key: CharKey, _ result: Result<Bool, Error>) {
    lock.lock(); let latch = notifyWaiters[key]; lock.unlock()
    latch?.fulfill(result)
  }

  func fulfillRSSI(_ id: Data, _ result: Result<Int64, Error>) {
    lock.lock(); let latch = rssiWaiters[id]; lock.unlock()
    latch?.fulfill(result)
  }
}
