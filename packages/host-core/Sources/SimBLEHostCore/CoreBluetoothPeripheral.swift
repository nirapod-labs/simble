// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import CoreBluetooth
import Foundation
import SimBLEProtocol

/// The real peripheral driver: a `CBPeripheralManager` behind the `PeripheralBackend`
/// surface. A command that has a delegate callback blocks the calling thread on a latch
/// until it fires or a deadline passes; unsolicited results (a read or write request, a
/// subscription change, a state change, the transmit queue draining) go to the event
/// sink.
///
/// The bridge moves GATT traffic only. No pairing secret or key material is read,
/// stored, or relayed by this driver.
public final class CoreBluetoothPeripheral: NSObject, PeripheralBackend, @unchecked Sendable {
  /// How long a command waits for its delegate callback before reporting a timeout.
  private static let commandTimeout: TimeInterval = 10

  private let queue = DispatchQueue(label: "simble.peripheral")
  private var manager: CBPeripheralManager!
  private let lock = NSLock()

  /// Published services keyed by UUID string, with their characteristics.
  private var services: [String: CBMutableService] = [:]
  /// Incoming ATT requests keyed by the id minted when raising the event, consumed by a respond.
  private var pendingRequests: [UInt64: CBATTRequest] = [:]
  private var nextRequestId: UInt64 = 1
  // Pending command latches, signaled by the delegate callback.
  private var addServiceWaiters: [String: Latch<Void>] = [:]
  private var advertisingWaiter: Latch<Void>?
  private var eventSink: (@Sendable (PeripheralBackendEvent) -> Void)?

  /// Build the driver and start the manager on its own queue. The manager reaches
  /// `poweredOn` asynchronously; `managerState()` observes it.
  override public init() {
    super.init()
    manager = CBPeripheralManager(delegate: self, queue: queue)
  }

  public func setEventSink(_ sink: @escaping @Sendable (PeripheralBackendEvent) -> Void) {
    lock.lock()
    eventSink = sink
    lock.unlock()
  }

  public func managerState() -> UInt64 {
    UInt64(max(0, manager.state.rawValue))
  }

  public func addService(serviceUUID: String, isPrimary: Bool,
                         characteristics: [CharacteristicSpec]) throws
  {
    let service = CBMutableService(type: CBUUID(string: serviceUUID), primary: isPrimary)
    service.characteristics = characteristics.map {
      CBMutableCharacteristic(
        type: CBUUID(string: $0.uuid),
        properties: CBCharacteristicProperties(rawValue: UInt(truncatingIfNeeded: $0.properties)),
        value: nil,
        permissions: CBAttributePermissions(rawValue: UInt(truncatingIfNeeded: $0.permissions))
      )
    }
    let latch = Latch<Void>()
    setAddServiceWaiter(latch, for: serviceUUID)
    // Replace any service already registered under this UUID so a guest relaunch against the
    // long-lived manager leaves no duplicate primary service in the GATT database.
    lock.lock(); let previous = services[serviceUUID]; services[serviceUUID] = service; lock
      .unlock()
    queue.async {
      if let previous { self.manager.remove(previous) }
      self.manager.add(service)
    }
    _ = try wait(latch) { self.clearAddServiceWaiter(serviceUUID) }
  }

  public func removeService(serviceUUID: String) throws {
    let service = try service(serviceUUID)
    lock.lock(); services[serviceUUID] = nil; lock.unlock()
    queue.async { self.manager.remove(service) }
  }

  public func startAdvertising(localName: String?, serviceUUIDs: [String]?) throws {
    var data: [String: Any] = [:]
    if let localName { data[CBAdvertisementDataLocalNameKey] = localName }
    if let serviceUUIDs {
      data[CBAdvertisementDataServiceUUIDsKey] = serviceUUIDs.map { CBUUID(string: $0) }
    }
    let latch = Latch<Void>()
    setAdvertisingWaiter(latch)
    // Restart so a repeat call replaces the live advertisement instead of failing with
    // CBErrorAlreadyAdvertising.
    queue.async {
      if self.manager.isAdvertising { self.manager.stopAdvertising() }
      self.manager.startAdvertising(data)
    }
    _ = try wait(latch) { self.clearAdvertisingWaiter() }
  }

  public func stopAdvertising() throws {
    queue.async { self.manager.stopAdvertising() }
  }

  public func respondRead(requestId: UInt64, value: Data, attError: UInt64) throws {
    let request = try takeRequest(requestId)
    request.value = value
    queue.async { self.manager.respond(to: request, withResult: Self.result(attError)) }
  }

  public func respondWrite(requestId: UInt64, attError: UInt64) throws {
    let request = try takeRequest(requestId)
    queue.async { self.manager.respond(to: request, withResult: Self.result(attError)) }
  }

  public func updateValue(serviceUUID: String, characteristicUUID: String, value: Data,
                          centralId: Data?) throws
  {
    let characteristic = try characteristic(characteristicUUID, serviceUUID: serviceUUID)
    let centrals = centralId.flatMap { id in subscribedCentrals(characteristic).filter {
      Self.identifier(of: $0) == id
    } }
    queue.async {
      _ = self.manager.updateValue(value, for: characteristic, onSubscribedCentrals: centrals)
    }
  }

  // MARK: lookup

  private func service(_ uuid: String) throws -> CBMutableService {
    lock.lock(); let service = services[uuid]; lock.unlock()
    guard let service else {
      throw PeripheralBackendError(code: Self.unknownAttribute, message: "service not published")
    }
    return service
  }

  private func characteristic(_ uuid: String, serviceUUID: String) throws -> CBMutableCharacteristic
  {
    lock.lock(); let published = services; lock.unlock()
    guard let characteristic = Self.resolveCharacteristic(uuid, serviceUUID: serviceUUID,
                                                          in: published)
    else {
      throw PeripheralBackendError(code: Self.unknownAttribute,
                                   message: "characteristic not published")
    }
    return characteristic
  }

  /// The published characteristic with UUID `uuid`, searched in the service named by
  /// `serviceUUID` first and then in every other published service. The fallback covers a
  /// peripheral-created `CBMutableCharacteristic`, which carries no service back-reference.
  static func resolveCharacteristic(_ uuid: String, serviceUUID: String,
                                    in services: [String: CBMutableService])
    -> CBMutableCharacteristic?
  {
    let target = CBUUID(string: uuid)
    let ordered = [services[serviceUUID]].compactMap { $0 }
      + services.values.filter { $0.uuid.uuidString != serviceUUID }
    for service in ordered {
      if let characteristic = (service.characteristics as? [CBMutableCharacteristic])?
        .first(where: { $0.uuid == target })
      {
        return characteristic
      }
    }
    return nil
  }

  private func subscribedCentrals(_ characteristic: CBMutableCharacteristic) -> [CBCentral] {
    characteristic.subscribedCentrals ?? []
  }

  private static func identifier(of central: CBCentral) -> Data {
    withUnsafeBytes(of: central.identifier.uuid) { Data($0) }
  }

  private static func result(_ attError: UInt64) -> CBATTError.Code {
    CBATTError.Code(rawValue: Int(truncatingIfNeeded: attError)) ?? .success
  }

  // MARK: request bookkeeping

  /// Record an incoming ATT request under a freshly minted id and return that id.
  private func record(_ request: CBATTRequest) -> UInt64 {
    lock.lock()
    let id = nextRequestId
    nextRequestId &+= 1
    pendingRequests[id] = request
    lock.unlock()
    return id
  }

  private func takeRequest(_ id: UInt64) throws -> CBATTRequest {
    lock.lock(); let request = pendingRequests.removeValue(forKey: id); lock.unlock()
    guard let request else {
      throw PeripheralBackendError(code: Self.unknownAttribute, message: "unknown request")
    }
    return request
  }

  private func wait<T>(_ latch: Latch<T>, cleanup: () -> Void) throws -> T {
    defer { cleanup() }
    guard let outcome = latch.wait(timeout: Self.commandTimeout) else {
      throw PeripheralBackendError(code: Self.timeout, message: "command timed out")
    }
    return try outcome.get()
  }

  private func emit(_ event: PeripheralBackendEvent) {
    lock.lock()
    let sink = eventSink
    lock.unlock()
    sink?(event)
  }
}

private extension CoreBluetoothPeripheral {
  static let unknownAttribute: Int64 = 4 // CBATTError.attributeNotFound
  static let timeout: Int64 = 9 // CBError.connectionTimeout
  static let opFailed: Int64 = 1 // CBError.unknown

  func setAddServiceWaiter(_ latch: Latch<Void>, for uuid: String) {
    lock.lock(); addServiceWaiters[uuid] = latch; lock.unlock()
  }

  func clearAddServiceWaiter(_ uuid: String) {
    lock.lock(); addServiceWaiters[uuid] = nil; lock.unlock()
  }

  func setAdvertisingWaiter(_ latch: Latch<Void>) {
    lock.lock(); advertisingWaiter = latch; lock.unlock()
  }

  func clearAdvertisingWaiter() {
    lock.lock(); advertisingWaiter = nil; lock.unlock()
  }
}

// MARK: CBPeripheralManagerDelegate

extension CoreBluetoothPeripheral: CBPeripheralManagerDelegate {
  public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    emit(.stateChanged(state: UInt64(max(0, peripheral.state.rawValue))))
  }

  public func peripheralManager(_: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    let uuid = service.uuid.uuidString
    lock.lock(); let latch = addServiceWaiters[uuid]; lock.unlock()
    if let error {
      latch?.fulfill(.failure(Self.backendError(error, fallback: "add service failed")))
      return
    }
    latch?.fulfill(.success(()))
  }

  public func peripheralManagerDidStartAdvertising(_: CBPeripheralManager, error: Error?) {
    lock.lock(); let latch = advertisingWaiter; lock.unlock()
    if let error {
      latch?.fulfill(.failure(Self.backendError(error, fallback: "start advertising failed")))
      return
    }
    latch?.fulfill(.success(()))
  }

  public func peripheralManager(_: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    let id = record(request)
    let characteristic = request.characteristic
    emit(.readRequest(requestId: id,
                      serviceUUID: characteristic.service?.uuid.uuidString ?? "",
                      characteristicUUID: characteristic.uuid.uuidString,
                      offset: UInt64(max(0, request.offset)),
                      centralId: Self.identifier(of: request.central)))
  }

  public func peripheralManager(_: CBPeripheralManager,
                                didReceiveWrite requests: [CBATTRequest])
  {
    for request in requests {
      let id = record(request)
      let characteristic = request.characteristic
      emit(.writeRequest(requestId: id,
                         serviceUUID: characteristic.service?.uuid.uuidString ?? "",
                         characteristicUUID: characteristic.uuid.uuidString,
                         value: request.value ?? Data(),
                         offset: UInt64(max(0, request.offset)),
                         centralId: Self.identifier(of: request.central)))
    }
  }

  public func peripheralManager(_: CBPeripheralManager, central: CBCentral,
                                didSubscribeTo characteristic: CBCharacteristic)
  {
    emit(.subscribed(serviceUUID: characteristic.service?.uuid.uuidString ?? "",
                     characteristicUUID: characteristic.uuid.uuidString,
                     centralId: Self.identifier(of: central),
                     mtu: UInt64(central.maximumUpdateValueLength)))
  }

  public func peripheralManager(_: CBPeripheralManager, central: CBCentral,
                                didUnsubscribeFrom characteristic: CBCharacteristic)
  {
    emit(.unsubscribed(serviceUUID: characteristic.service?.uuid.uuidString ?? "",
                       characteristicUUID: characteristic.uuid.uuidString,
                       centralId: Self.identifier(of: central)))
  }

  public func peripheralManagerIsReady(toUpdateSubscribers _: CBPeripheralManager) {
    emit(.readyToUpdate)
  }
}

private extension CoreBluetoothPeripheral {
  static func backendError(_ error: Error?, fallback: String) -> PeripheralBackendError {
    guard let error = error as NSError? else {
      return PeripheralBackendError(code: opFailed, message: fallback)
    }
    return PeripheralBackendError(code: Int64(error.code), message: error.localizedDescription)
  }
}
