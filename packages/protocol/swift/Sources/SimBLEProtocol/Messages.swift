// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation

/// How a central writes a characteristic, mirroring `CBCharacteristicWriteType`. A
/// `withResponse` write expects a host acknowledgement; a `withoutResponse` write
/// does not, so its response confirms only that the host accepted the request.
public enum WriteType: UInt64, Sendable {
  case withResponse = 0
  case withoutResponse = 1
}

/// An advertisement the host observed while scanning, carried in a `discovered`
/// event. Every field past the peripheral id and RSSI is optional, exactly as
/// CoreBluetooth surfaces an advertisement dictionary that omits absent keys.
public struct Advertisement: Equatable, Sendable {
  /// The advertised local name, when present.
  public let localName: String?
  /// The service UUIDs the advertisement listed, when present.
  public let serviceUUIDs: [String]?
  /// The advertised TX power level in dBm, when present.
  public let txPower: Int64?
  /// The advertised manufacturer-specific data, when present.
  public let manufacturerData: Data?
  /// Wrap an observed advertisement's optional fields.
  public init(localName: String? = nil, serviceUUIDs: [String]? = nil,
              txPower: Int64? = nil, manufacturerData: Data? = nil)
  {
    self.localName = localName
    self.serviceUUIDs = serviceUUIDs
    self.txPower = txPower
    self.manufacturerData = manufacturerData
  }
}

/// A characteristic the guest declares when adding a local service, with the
/// `CBCharacteristicProperties` and the attribute permissions the guest set.
public struct CharacteristicSpec: Equatable, Sendable {
  /// The characteristic UUID as a `CBUUID` string.
  public let uuid: String
  /// The raw `CBCharacteristicProperties` bit set.
  public let properties: UInt64
  /// The raw `CBAttributePermissions` bit set.
  public let permissions: UInt64
  /// Wrap a declared characteristic.
  public init(uuid: String, properties: UInt64, permissions: UInt64) {
    self.uuid = uuid
    self.properties = properties
    self.permissions = permissions
  }
}

/// A request from the interposer (guest, the simulated app) to the helper (host).
/// Every request carries the capability token in key 7, validated before the op.
public enum Request: Equatable {
  /// Version negotiation; the helper answers with the version it speaks.
  case hello(version: UInt64)
  /// Read the host central manager's `CBManagerState`.
  case centralState
  /// Start scanning, optionally filtered to the given service UUIDs.
  case scanStart(serviceUUIDs: [String]?)
  /// Stop scanning.
  case scanStop
  /// Connect to the peripheral named by the host identifier.
  case connect(peripheralId: Data)
  /// Cancel the connection to the named peripheral.
  case disconnect(peripheralId: Data)
  /// Discover services on a connected peripheral, optionally filtered.
  case discoverServices(peripheralId: Data, serviceUUIDs: [String]?)
  /// Discover characteristics of a service on a connected peripheral, optionally filtered.
  case discoverCharacteristics(peripheralId: Data, serviceUUID: String,
                               characteristicUUIDs: [String]?)
  /// Read one characteristic's value (central role).
  case readCharacteristic(peripheralId: Data, serviceUUID: String, characteristicUUID: String)
  /// Write a characteristic's value (central role), with or without a response.
  case writeCharacteristic(peripheralId: Data, serviceUUID: String, characteristicUUID: String,
                           value: Data, writeType: WriteType)
  /// Enable or disable notifications/indications for a characteristic (central role).
  case setNotify(peripheralId: Data, serviceUUID: String, characteristicUUID: String,
                 enabled: Bool)
  /// Read the current RSSI of a connected peripheral.
  case readRSSI(peripheralId: Data)
  /// Read a connected peripheral's `CBPeripheralState`.
  case peripheralState(peripheralId: Data)
  /// Publish a local GATT service (peripheral role) with its characteristics.
  case addService(serviceUUID: String, isPrimary: Bool, characteristics: [CharacteristicSpec])
  /// Remove a previously published local service (peripheral role).
  case removeService(serviceUUID: String)
  /// Begin advertising the local peripheral, optionally with a name and service UUIDs.
  case startAdvertising(localName: String?, serviceUUIDs: [String]?)
  /// Stop advertising the local peripheral.
  case stopAdvertising
  /// Respond to an incoming read request (peripheral role) the host raised as a `readRequest`
  /// event, returning the value and an ATT result.
  case respondRead(requestId: UInt64, value: Data, attError: UInt64)
  /// Respond to an incoming write request (peripheral role) the host raised as a `writeRequest`
  /// event, returning an ATT result.
  case respondWrite(requestId: UInt64, attError: UInt64)
  /// Push a new value for a local characteristic to subscribed centrals, or to one central when
  /// `centralId` is set (peripheral role).
  case updateValue(serviceUUID: String, characteristicUUID: String, value: Data,
                   centralId: Data?)
}

/// A reply from the helper (host) to the interposer (guest). A response echoes the
/// request's op in key 0, carries the status in key 1, and never carries the token.
public enum Response: Equatable {
  /// The version the helper speaks.
  case hello(version: UInt64)
  /// The host central manager's `CBManagerState`.
  case centralState(state: UInt64)
  /// Scanning started.
  case scanStarted
  /// Scanning stopped.
  case scanStopped
  /// The named peripheral connected.
  case connected(peripheralId: Data)
  /// The named peripheral disconnected on request.
  case disconnected(peripheralId: Data)
  /// The services discovered on a peripheral.
  case servicesDiscovered(peripheralId: Data, serviceUUIDs: [String])
  /// The characteristics discovered for a service.
  case characteristicsDiscovered(peripheralId: Data, serviceUUID: String,
                                 characteristicUUIDs: [String])
  /// A characteristic's read value (central role).
  case characteristicValue(peripheralId: Data, serviceUUID: String, characteristicUUID: String,
                           value: Data)
  /// A write was accepted by the host.
  case wrote
  /// The notification state the host set for a characteristic.
  case notifyState(peripheralId: Data, serviceUUID: String, characteristicUUID: String,
                   enabled: Bool)
  /// The peripheral's current RSSI.
  case rssi(peripheralId: Data, rssi: Int64)
  /// A peripheral's `CBPeripheralState`.
  case peripheralState(peripheralId: Data, state: UInt64)
  /// A local service was published.
  case serviceAdded(serviceUUID: String)
  /// A local service was removed.
  case serviceRemoved(serviceUUID: String)
  /// Advertising started.
  case advertisingStarted
  /// Advertising stopped.
  case advertisingStopped
  /// A read request was answered.
  case readResponded
  /// A write request was answered.
  case writeResponded
  /// A characteristic update was sent to the subscribed centrals.
  case valueUpdated
  /// An error: a device-shaped `CBError`/`CBATTError` numeric code plus a human-readable
  /// message that is never load-bearing.
  case failure(op: UInt64, code: Int64, message: String)
}

/// An unsolicited event the helper (host) raises to the interposer (guest). An
/// event carries neither the token nor a status; its op is in the high range.
public enum Event: Equatable {
  /// A peripheral was seen while scanning, with its advertisement and RSSI.
  case discovered(peripheralId: Data, advertisement: Advertisement, rssi: Int64)
  /// A subscribed characteristic delivered a notification or indication (central role).
  case characteristicValue(peripheralId: Data, serviceUUID: String, characteristicUUID: String,
                           value: Data)
  /// A peripheral disconnected unexpectedly; `errorCode` is the `CBError` when one applied.
  case peripheralDisconnected(peripheralId: Data, errorCode: Int64?)
  /// The host central manager's `CBManagerState` changed.
  case centralStateChanged(state: UInt64)
  /// The host peripheral manager's `CBManagerState` changed.
  case peripheralStateChanged(state: UInt64)
  /// A connected central asked to read a local characteristic (peripheral role); answer with
  /// `respondRead` carrying the same `requestId`.
  case readRequest(requestId: UInt64, serviceUUID: String, characteristicUUID: String,
                   offset: UInt64, centralId: Data)
  /// A connected central asked to write a local characteristic (peripheral role); answer with
  /// `respondWrite` carrying the same `requestId`.
  case writeRequest(requestId: UInt64, serviceUUID: String, characteristicUUID: String,
                    value: Data, offset: UInt64, centralId: Data)
  /// A central subscribed to a local characteristic (peripheral role); `mtu` is its
  /// maximum update value length.
  case subscribed(serviceUUID: String, characteristicUUID: String, centralId: Data, mtu: UInt64)
  /// A central unsubscribed from a local characteristic (peripheral role).
  case unsubscribed(serviceUUID: String, characteristicUUID: String, centralId: Data)
  /// The peripheral manager's transmit queue has room again after a failed `updateValue`.
  case readyToUpdate
}

/// The version-1 message codec: a CBOR map in and out (see `SPEC.md`). Socket
/// I/O and framing live elsewhere; this is the pure payload layer. Requests carry
/// the capability token; responses and events never do.
public enum Wire {
  // Command ops: a request and its matching response share one op (1 through 20).
  static let opHello: UInt64 = 1
  static let opCentralState: UInt64 = 2
  static let opScanStart: UInt64 = 3
  static let opScanStop: UInt64 = 4
  static let opConnect: UInt64 = 5
  static let opDisconnect: UInt64 = 6
  static let opDiscoverServices: UInt64 = 7
  static let opDiscoverCharacteristics: UInt64 = 8
  static let opReadCharacteristic: UInt64 = 9
  static let opWriteCharacteristic: UInt64 = 10
  static let opSetNotify: UInt64 = 11
  static let opReadRSSI: UInt64 = 12
  static let opPeripheralState: UInt64 = 13
  static let opAddService: UInt64 = 14
  static let opRemoveService: UInt64 = 15
  static let opStartAdvertising: UInt64 = 16
  static let opStopAdvertising: UInt64 = 17
  static let opRespondRead: UInt64 = 18
  static let opRespondWrite: UInt64 = 19
  static let opUpdateValue: UInt64 = 20

  // Event ops live at 128 and up; request and response ops are 1...20.
  static let opDiscovered: UInt64 = 128
  static let opCharValue: UInt64 = 129
  static let opDisconnectedEvent: UInt64 = 130
  static let opCentralStateChanged: UInt64 = 131
  static let opPeripheralStateChanged: UInt64 = 132
  static let opReadRequest: UInt64 = 133
  static let opWriteRequest: UInt64 = 134
  static let opSubscribed: UInt64 = 135
  static let opUnsubscribed: UInt64 = 136
  static let opReadyToUpdate: UInt64 = 137

  static let statusOK: UInt64 = 0
  static let statusError: UInt64 = 1
  /// The protocol version this codec implements.
  public static let version1: UInt64 = 1

  // Shared keys, reused from the SimEnclave wire so a reader of both protocols sees the same
  // numbers for op, status, error, token, version, errorCode, appId, and appDisplayName.
  static let keyOp: UInt64 = 0
  static let keyStatus: UInt64 = 1
  static let keyError: UInt64 = 6
  static let keyToken: UInt64 = 7
  static let keyVersion: UInt64 = 8
  static let keyErrorCode: UInt64 = 10
  static let keyAppID: UInt64 = 14
  static let keyAppDisplayName: UInt64 = 28

  // BLE fields.
  static let keyPeripheralId: UInt64 = 30
  static let keyServiceUUID: UInt64 = 31
  static let keyCharacteristicUUID: UInt64 = 32
  static let keyValue: UInt64 = 33
  static let keyRSSI: UInt64 = 34
  static let keyLocalName: UInt64 = 35
  static let keyAdvertisedServiceUUIDs: UInt64 = 36
  static let keyTxPower: UInt64 = 37
  static let keyManufacturerData: UInt64 = 38
  static let keyWriteType: UInt64 = 39
  static let keyNotify: UInt64 = 40
  static let keyManagerState: UInt64 = 41
  static let keyRequestId: UInt64 = 42
  static let keyATTOffset: UInt64 = 43
  static let keyCharProperties: UInt64 = 44
  static let keyATTPermissions: UInt64 = 45
  static let keyIsPrimary: UInt64 = 46
  static let keyCentralId: UInt64 = 47
  static let keyMTU: UInt64 = 48
  static let keyATTError: UInt64 = 49
  static let keyServiceUUIDs: UInt64 = 50
  static let keyCharacteristicUUIDs: UInt64 = 51

  /// The most Unicode scalars the helper keeps from a guest display name. Clamping scalars, not
  /// graphemes, bounds the rendered width even when a name stacks unbounded combining marks.
  public static let maxAppDisplayNameScalars = 64

  /// Encode a request, carrying the capability token in key 7. The token rides
  /// every request; the helper validates it before interpreting the op.
  public static func encode(_ request: Request, token: Data, appID: String? = nil,
                            displayName: String? = nil) -> Data
  {
    var writer = CBORWriter()
    switch request {
    case let .hello(version):
      // HELLO carries the session identity once: op, token, version, then the optional
      // app id (14) and display name (28) in ascending key order.
      var count = 3
      if appID != nil { count += 1 }
      if displayName != nil { count += 1 }
      writer.mapHeader(count)
      writer.uint(keyOp); writer.uint(opHello)
      writer.uint(keyToken); writer.bytes(token)
      writer.uint(keyVersion); writer.uint(version)
      if let appID { writer.uint(keyAppID); writer.text(appID) }
      if let displayName { writer.uint(keyAppDisplayName); writer.text(displayName) }
    case .centralState:
      writer.mapHeader(2)
      writer.uint(keyOp); writer.uint(opCentralState)
      writer.uint(keyToken); writer.bytes(token)
    case let .scanStart(serviceUUIDs):
      writer.mapHeader(serviceUUIDs != nil ? 3 : 2)
      writer.uint(keyOp); writer.uint(opScanStart)
      writer.uint(keyToken); writer.bytes(token)
      if let serviceUUIDs { writer.uint(keyServiceUUIDs); writer.textArray(serviceUUIDs) }
    case .scanStop:
      writer.mapHeader(2)
      writer.uint(keyOp); writer.uint(opScanStop)
      writer.uint(keyToken); writer.bytes(token)
    case let .connect(peripheralId):
      encodeHandleRequest(&writer, op: opConnect, token: token, peripheralId: peripheralId)
    case let .disconnect(peripheralId):
      encodeHandleRequest(&writer, op: opDisconnect, token: token, peripheralId: peripheralId)
    case let .discoverServices(peripheralId, serviceUUIDs):
      writer.mapHeader(serviceUUIDs != nil ? 4 : 3)
      writer.uint(keyOp); writer.uint(opDiscoverServices)
      writer.uint(keyToken); writer.bytes(token)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      if let serviceUUIDs { writer.uint(keyServiceUUIDs); writer.textArray(serviceUUIDs) }
    case let .discoverCharacteristics(peripheralId, serviceUUID, characteristicUUIDs):
      writer.mapHeader(characteristicUUIDs != nil ? 5 : 4)
      writer.uint(keyOp); writer.uint(opDiscoverCharacteristics)
      writer.uint(keyToken); writer.bytes(token)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      if let characteristicUUIDs {
        writer.uint(keyCharacteristicUUIDs); writer.textArray(characteristicUUIDs)
      }
    case let .readCharacteristic(peripheralId, serviceUUID, characteristicUUID):
      writer.mapHeader(5)
      writer.uint(keyOp); writer.uint(opReadCharacteristic)
      writer.uint(keyToken); writer.bytes(token)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUID); writer.text(characteristicUUID)
    case let .writeCharacteristic(peripheralId, serviceUUID, characteristicUUID, value, type):
      writer.mapHeader(7)
      writer.uint(keyOp); writer.uint(opWriteCharacteristic)
      writer.uint(keyToken); writer.bytes(token)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUID); writer.text(characteristicUUID)
      writer.uint(keyValue); writer.bytes(value)
      writer.uint(keyWriteType); writer.uint(type.rawValue)
    case let .setNotify(peripheralId, serviceUUID, characteristicUUID, enabled):
      writer.mapHeader(6)
      writer.uint(keyOp); writer.uint(opSetNotify)
      writer.uint(keyToken); writer.bytes(token)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUID); writer.text(characteristicUUID)
      writer.uint(keyNotify); writer.uint(enabled ? 1 : 0)
    case let .readRSSI(peripheralId):
      encodeHandleRequest(&writer, op: opReadRSSI, token: token, peripheralId: peripheralId)
    case let .peripheralState(peripheralId):
      encodeHandleRequest(&writer, op: opPeripheralState, token: token,
                          peripheralId: peripheralId)
    case let .addService(serviceUUID, isPrimary, characteristics):
      // op, token, serviceUUID (31), isPrimary (46), then the characteristic UUIDs (51) and
      // their parallel properties (44) and permissions (45), each a flat array entry, keys
      // ascending. The three arrays are positionally aligned, one entry per characteristic.
      writer.mapHeader(7)
      writer.uint(keyOp); writer.uint(opAddService)
      writer.uint(keyToken); writer.bytes(token)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharProperties); writer.bytes(packUInts(characteristics.map(\.properties)))
      writer.uint(keyATTPermissions); writer.bytes(packUInts(characteristics.map(\.permissions)))
      writer.uint(keyIsPrimary); writer.uint(isPrimary ? 1 : 0)
      writer.uint(keyCharacteristicUUIDs); writer.textArray(characteristics.map(\.uuid))
    case let .removeService(serviceUUID):
      writer.mapHeader(3)
      writer.uint(keyOp); writer.uint(opRemoveService)
      writer.uint(keyToken); writer.bytes(token)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
    case let .startAdvertising(localName, serviceUUIDs):
      var count = 2
      if localName != nil { count += 1 }
      if serviceUUIDs != nil { count += 1 }
      writer.mapHeader(count)
      writer.uint(keyOp); writer.uint(opStartAdvertising)
      writer.uint(keyToken); writer.bytes(token)
      if let localName { writer.uint(keyLocalName); writer.text(localName) }
      if let serviceUUIDs {
        writer.uint(keyAdvertisedServiceUUIDs); writer.textArray(serviceUUIDs)
      }
    case .stopAdvertising:
      writer.mapHeader(2)
      writer.uint(keyOp); writer.uint(opStopAdvertising)
      writer.uint(keyToken); writer.bytes(token)
    case let .respondRead(requestId, value, attError):
      writer.mapHeader(5)
      writer.uint(keyOp); writer.uint(opRespondRead)
      writer.uint(keyToken); writer.bytes(token)
      writer.uint(keyValue); writer.bytes(value)
      writer.uint(keyRequestId); writer.uint(requestId)
      writer.uint(keyATTError); writer.uint(attError)
    case let .respondWrite(requestId, attError):
      writer.mapHeader(4)
      writer.uint(keyOp); writer.uint(opRespondWrite)
      writer.uint(keyToken); writer.bytes(token)
      writer.uint(keyRequestId); writer.uint(requestId)
      writer.uint(keyATTError); writer.uint(attError)
    case let .updateValue(serviceUUID, characteristicUUID, value, centralId):
      // op, token, serviceUUID (31), characteristicUUID (32), value (33), then the optional
      // target central (47); absent means every subscribed central. Keys ascending.
      writer.mapHeader(centralId != nil ? 6 : 5)
      writer.uint(keyOp); writer.uint(opUpdateValue)
      writer.uint(keyToken); writer.bytes(token)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUID); writer.text(characteristicUUID)
      writer.uint(keyValue); writer.bytes(value)
      if let centralId { writer.uint(keyCentralId); writer.bytes(centralId) }
    }
    return writer.data
  }

  /// op, token, peripheralId (30): the shape every peripheral-directed request with no other
  /// argument shares (connect, disconnect, readRSSI, peripheralState). Keys ascending.
  private static func encodeHandleRequest(_ writer: inout CBORWriter, op: UInt64, token: Data,
                                          peripheralId: Data)
  {
    writer.mapHeader(3)
    writer.uint(keyOp); writer.uint(op)
    writer.uint(keyToken); writer.bytes(token)
    writer.uint(keyPeripheralId); writer.bytes(peripheralId)
  }

  /// Pack unsigned values into one byte string: a 2-byte big-endian count, then each value as
  /// 8 big-endian bytes. `addService` carries a characteristic's properties and permissions this
  /// way, positionally aligned with the characteristic UUID array, so the map codec needs no
  /// integer-array support and both codecs agree byte for byte.
  static func packUInts(_ values: [UInt64]) -> Data {
    var d = Data()
    d.append(UInt8(truncatingIfNeeded: values.count >> 8))
    d.append(UInt8(truncatingIfNeeded: values.count))
    for v in values {
      for shift in stride(from: 56, through: 0, by: -8) {
        d.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
      }
    }
    return d
  }

  /// Inverse of `packUInts`. Throws on a truncated or inconsistent blob.
  static func unpackUInts(_ blob: Data) throws -> [UInt64] {
    let b = [UInt8](blob)
    guard b.count >= 2 else { throw ProtocolError.truncated }
    let count = (Int(b[0]) << 8) | Int(b[1])
    guard b.count == 2 + count * 8 else { throw ProtocolError.truncated }
    var values: [UInt64] = []
    values.reserveCapacity(count)
    var i = 2
    for _ in 0 ..< count {
      var v: UInt64 = 0
      for _ in 0 ..< 8 {
        v = (v << 8) | UInt64(b[i]); i += 1
      }
      values.append(v)
    }
    return values
  }

  /// The capability token from a request, key 7. Read before the op so an
  /// auth gate can reject without interpreting the operation.
  public static func token(in payload: Data) throws -> Data {
    try CBORMap(decoding: payload).bytes(keyToken)
  }

  /// The interposer-reported app id from a request, key 14, if present. Guest-reported, so it
  /// names the app for display but gates nothing.
  public static func appID(in payload: Data) -> String? {
    (try? CBORMap(decoding: payload))?.optionalText(keyAppID)
  }

  /// The guest-reported display name from a HELLO, key 28, if present. Guest-reported and
  /// untrusted: the caller clamps and sanitizes it before display, and it gates nothing.
  public static func appDisplayName(in payload: Data) -> String? {
    (try? CBORMap(decoding: payload))?.optionalText(keyAppDisplayName)
  }

  /// Decode a request payload, dispatching on the op in key 0.
  ///
  /// - Throws: `ProtocolError` when the bytes are not canonical CBOR, a
  ///   required field is absent, or the op is unknown.
  public static func decodeRequest(_ payload: Data) throws -> Request {
    let map = try CBORMap(decoding: payload)
    switch try map.uint(keyOp) {
    case opHello:
      return try .hello(version: map.uint(keyVersion))
    case opCentralState:
      return .centralState
    case opScanStart:
      return .scanStart(serviceUUIDs: map.optionalTextArray(keyServiceUUIDs))
    case opScanStop:
      return .scanStop
    case opConnect:
      return try .connect(peripheralId: map.bytes(keyPeripheralId))
    case opDisconnect:
      return try .disconnect(peripheralId: map.bytes(keyPeripheralId))
    case opDiscoverServices:
      return try .discoverServices(peripheralId: map.bytes(keyPeripheralId),
                                   serviceUUIDs: map.optionalTextArray(keyServiceUUIDs))
    case opDiscoverCharacteristics:
      return try .discoverCharacteristics(
        peripheralId: map.bytes(keyPeripheralId),
        serviceUUID: map.text(keyServiceUUID),
        characteristicUUIDs: map.optionalTextArray(keyCharacteristicUUIDs)
      )
    case opReadCharacteristic:
      return try .readCharacteristic(peripheralId: map.bytes(keyPeripheralId),
                                     serviceUUID: map.text(keyServiceUUID),
                                     characteristicUUID: map.text(keyCharacteristicUUID))
    case opWriteCharacteristic:
      let type = try WriteType(rawValue: map.uint(keyWriteType)) ?? .withResponse
      return try .writeCharacteristic(peripheralId: map.bytes(keyPeripheralId),
                                      serviceUUID: map.text(keyServiceUUID),
                                      characteristicUUID: map.text(keyCharacteristicUUID),
                                      value: map.bytes(keyValue), writeType: type)
    case opSetNotify:
      return try .setNotify(peripheralId: map.bytes(keyPeripheralId),
                            serviceUUID: map.text(keyServiceUUID),
                            characteristicUUID: map.text(keyCharacteristicUUID),
                            enabled: map.uint(keyNotify) != 0)
    case opReadRSSI:
      return try .readRSSI(peripheralId: map.bytes(keyPeripheralId))
    case opPeripheralState:
      return try .peripheralState(peripheralId: map.bytes(keyPeripheralId))
    case opAddService:
      let uuids = try map.textArray(keyCharacteristicUUIDs)
      let properties = try unpackUInts(map.bytes(keyCharProperties))
      let permissions = try unpackUInts(map.bytes(keyATTPermissions))
      guard uuids.count == properties.count, uuids.count == permissions.count else {
        throw ProtocolError.malformed
      }
      let characteristics = (0 ..< uuids.count).map {
        CharacteristicSpec(uuid: uuids[$0], properties: properties[$0],
                           permissions: permissions[$0])
      }
      return try .addService(serviceUUID: map.text(keyServiceUUID),
                             isPrimary: map.uint(keyIsPrimary) != 0,
                             characteristics: characteristics)
    case opRemoveService:
      return try .removeService(serviceUUID: map.text(keyServiceUUID))
    case opStartAdvertising:
      return .startAdvertising(localName: map.optionalText(keyLocalName),
                               serviceUUIDs: map.optionalTextArray(keyAdvertisedServiceUUIDs))
    case opStopAdvertising:
      return .stopAdvertising
    case opRespondRead:
      return try .respondRead(requestId: map.uint(keyRequestId), value: map.bytes(keyValue),
                              attError: map.uint(keyATTError))
    case opRespondWrite:
      return try .respondWrite(requestId: map.uint(keyRequestId),
                               attError: map.uint(keyATTError))
    case opUpdateValue:
      return try .updateValue(serviceUUID: map.text(keyServiceUUID),
                              characteristicUUID: map.text(keyCharacteristicUUID),
                              value: map.bytes(keyValue),
                              centralId: map.optionalBytes(keyCentralId))
    case let other:
      throw ProtocolError.badOpcode(other)
    }
  }

  /// Encode a response. A response echoes the request's op, carries the status,
  /// and never carries the token.
  public static func encode(_ response: Response) -> Data {
    var writer = CBORWriter()
    switch response {
    case let .hello(version):
      writer.mapHeader(3)
      writer.uint(keyOp); writer.uint(opHello)
      writer.uint(keyStatus); writer.uint(statusOK)
      writer.uint(keyVersion); writer.uint(version)
    case let .centralState(state):
      writer.mapHeader(3)
      writer.uint(keyOp); writer.uint(opCentralState)
      writer.uint(keyStatus); writer.uint(statusOK)
      writer.uint(keyManagerState); writer.uint(state)
    case .scanStarted:
      encodeStatusOnly(&writer, op: opScanStart)
    case .scanStopped:
      encodeStatusOnly(&writer, op: opScanStop)
    case let .connected(peripheralId):
      encodeHandleResponse(&writer, op: opConnect, peripheralId: peripheralId)
    case let .disconnected(peripheralId):
      encodeHandleResponse(&writer, op: opDisconnect, peripheralId: peripheralId)
    case let .servicesDiscovered(peripheralId, serviceUUIDs):
      writer.mapHeader(4)
      writer.uint(keyOp); writer.uint(opDiscoverServices)
      writer.uint(keyStatus); writer.uint(statusOK)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyServiceUUIDs); writer.textArray(serviceUUIDs)
    case let .characteristicsDiscovered(peripheralId, serviceUUID, characteristicUUIDs):
      writer.mapHeader(5)
      writer.uint(keyOp); writer.uint(opDiscoverCharacteristics)
      writer.uint(keyStatus); writer.uint(statusOK)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUIDs); writer.textArray(characteristicUUIDs)
    case let .characteristicValue(peripheralId, serviceUUID, characteristicUUID, value):
      writer.mapHeader(6)
      writer.uint(keyOp); writer.uint(opReadCharacteristic)
      writer.uint(keyStatus); writer.uint(statusOK)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUID); writer.text(characteristicUUID)
      writer.uint(keyValue); writer.bytes(value)
    case .wrote:
      encodeStatusOnly(&writer, op: opWriteCharacteristic)
    case let .notifyState(peripheralId, serviceUUID, characteristicUUID, enabled):
      writer.mapHeader(6)
      writer.uint(keyOp); writer.uint(opSetNotify)
      writer.uint(keyStatus); writer.uint(statusOK)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUID); writer.text(characteristicUUID)
      writer.uint(keyNotify); writer.uint(enabled ? 1 : 0)
    case let .rssi(peripheralId, value):
      writer.mapHeader(4)
      writer.uint(keyOp); writer.uint(opReadRSSI)
      writer.uint(keyStatus); writer.uint(statusOK)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyRSSI); writer.int(value)
    case let .peripheralState(peripheralId, state):
      writer.mapHeader(4)
      writer.uint(keyOp); writer.uint(opPeripheralState)
      writer.uint(keyStatus); writer.uint(statusOK)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyManagerState); writer.uint(state)
    case let .serviceAdded(serviceUUID):
      encodeServiceResponse(&writer, op: opAddService, serviceUUID: serviceUUID)
    case let .serviceRemoved(serviceUUID):
      encodeServiceResponse(&writer, op: opRemoveService, serviceUUID: serviceUUID)
    case .advertisingStarted:
      encodeStatusOnly(&writer, op: opStartAdvertising)
    case .advertisingStopped:
      encodeStatusOnly(&writer, op: opStopAdvertising)
    case .readResponded:
      encodeStatusOnly(&writer, op: opRespondRead)
    case .writeResponded:
      encodeStatusOnly(&writer, op: opRespondWrite)
    case .valueUpdated:
      encodeStatusOnly(&writer, op: opUpdateValue)
    case let .failure(op, code, message):
      writer.mapHeader(4)
      writer.uint(keyOp); writer.uint(op)
      writer.uint(keyStatus); writer.uint(statusError)
      writer.uint(keyError); writer.text(message)
      writer.uint(keyErrorCode); writer.int(code)
    }
    return writer.data
  }

  /// A response that carries only the echoed op and an OK status (a confirmation).
  private static func encodeStatusOnly(_ writer: inout CBORWriter, op: UInt64) {
    writer.mapHeader(2)
    writer.uint(keyOp); writer.uint(op)
    writer.uint(keyStatus); writer.uint(statusOK)
  }

  /// A response echoing op, OK status, and a peripheral id (30).
  private static func encodeHandleResponse(_ writer: inout CBORWriter, op: UInt64,
                                           peripheralId: Data)
  {
    writer.mapHeader(3)
    writer.uint(keyOp); writer.uint(op)
    writer.uint(keyStatus); writer.uint(statusOK)
    writer.uint(keyPeripheralId); writer.bytes(peripheralId)
  }

  /// A response echoing op, OK status, and a service UUID (31).
  private static func encodeServiceResponse(_ writer: inout CBORWriter, op: UInt64,
                                            serviceUUID: String)
  {
    writer.mapHeader(3)
    writer.uint(keyOp); writer.uint(op)
    writer.uint(keyStatus); writer.uint(statusOK)
    writer.uint(keyServiceUUID); writer.text(serviceUUID)
  }

  /// Decode a response payload, dispatching on status then op.
  ///
  /// - Throws: `ProtocolError` when the bytes are not canonical CBOR, a
  ///   required field is absent, or the op or status is unknown.
  public static func decodeResponse(_ payload: Data) throws -> Response {
    let map = try CBORMap(decoding: payload)
    let status = try map.uint(keyStatus)
    if status == statusError {
      return try .failure(op: map.uint(keyOp), code: map.int(keyErrorCode),
                          message: map.text(keyError))
    }
    guard status == statusOK else { throw ProtocolError.badStatus(status) }
    switch try map.uint(keyOp) {
    case opHello:
      return try .hello(version: map.uint(keyVersion))
    case opCentralState:
      return try .centralState(state: map.uint(keyManagerState))
    case opScanStart:
      return .scanStarted
    case opScanStop:
      return .scanStopped
    case opConnect:
      return try .connected(peripheralId: map.bytes(keyPeripheralId))
    case opDisconnect:
      return try .disconnected(peripheralId: map.bytes(keyPeripheralId))
    case opDiscoverServices:
      return try .servicesDiscovered(peripheralId: map.bytes(keyPeripheralId),
                                     serviceUUIDs: map.textArray(keyServiceUUIDs))
    case opDiscoverCharacteristics:
      return try .characteristicsDiscovered(
        peripheralId: map.bytes(keyPeripheralId),
        serviceUUID: map.text(keyServiceUUID),
        characteristicUUIDs: map.textArray(keyCharacteristicUUIDs)
      )
    case opReadCharacteristic:
      return try .characteristicValue(peripheralId: map.bytes(keyPeripheralId),
                                      serviceUUID: map.text(keyServiceUUID),
                                      characteristicUUID: map.text(keyCharacteristicUUID),
                                      value: map.bytes(keyValue))
    case opWriteCharacteristic:
      return .wrote
    case opSetNotify:
      return try .notifyState(peripheralId: map.bytes(keyPeripheralId),
                              serviceUUID: map.text(keyServiceUUID),
                              characteristicUUID: map.text(keyCharacteristicUUID),
                              enabled: map.uint(keyNotify) != 0)
    case opReadRSSI:
      return try .rssi(peripheralId: map.bytes(keyPeripheralId), rssi: map.int(keyRSSI))
    case opPeripheralState:
      return try .peripheralState(peripheralId: map.bytes(keyPeripheralId),
                                  state: map.uint(keyManagerState))
    case opAddService:
      return try .serviceAdded(serviceUUID: map.text(keyServiceUUID))
    case opRemoveService:
      return try .serviceRemoved(serviceUUID: map.text(keyServiceUUID))
    case opStartAdvertising:
      return .advertisingStarted
    case opStopAdvertising:
      return .advertisingStopped
    case opRespondRead:
      return .readResponded
    case opRespondWrite:
      return .writeResponded
    case opUpdateValue:
      return .valueUpdated
    case let other:
      throw ProtocolError.badOpcode(other)
    }
  }

  /// Encode an event. Events carry neither the token nor a status; the op sits
  /// in the high range.
  public static func encode(_ event: Event) -> Data {
    var writer = CBORWriter()
    switch event {
    case let .discovered(peripheralId, advertisement, rssi):
      // op, peripheralId (30), rssi (34), then the optional advertisement fields
      // (localName 35, advertisedServiceUUIDs 36, txPower 37, manufacturerData 38),
      // keys ascending. RSSI is always present; the rest mirror an advertisement dictionary.
      var count = 3
      if advertisement.localName != nil { count += 1 }
      if advertisement.serviceUUIDs != nil { count += 1 }
      if advertisement.txPower != nil { count += 1 }
      if advertisement.manufacturerData != nil { count += 1 }
      writer.mapHeader(count)
      writer.uint(keyOp); writer.uint(opDiscovered)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyRSSI); writer.int(rssi)
      if let localName = advertisement.localName {
        writer.uint(keyLocalName); writer.text(localName)
      }
      if let serviceUUIDs = advertisement.serviceUUIDs {
        writer.uint(keyAdvertisedServiceUUIDs); writer.textArray(serviceUUIDs)
      }
      if let txPower = advertisement.txPower {
        writer.uint(keyTxPower); writer.int(txPower)
      }
      if let manufacturerData = advertisement.manufacturerData {
        writer.uint(keyManufacturerData); writer.bytes(manufacturerData)
      }
    case let .characteristicValue(peripheralId, serviceUUID, characteristicUUID, value):
      writer.mapHeader(5)
      writer.uint(keyOp); writer.uint(opCharValue)
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUID); writer.text(characteristicUUID)
      writer.uint(keyValue); writer.bytes(value)
    case let .peripheralDisconnected(peripheralId, errorCode):
      // op, errorCode (10) when an error applied, peripheralId (30), keys ascending.
      writer.mapHeader(errorCode != nil ? 3 : 2)
      writer.uint(keyOp); writer.uint(opDisconnectedEvent)
      if let errorCode { writer.uint(keyErrorCode); writer.int(errorCode) }
      writer.uint(keyPeripheralId); writer.bytes(peripheralId)
    case let .centralStateChanged(state):
      writer.mapHeader(2)
      writer.uint(keyOp); writer.uint(opCentralStateChanged)
      writer.uint(keyManagerState); writer.uint(state)
    case let .peripheralStateChanged(state):
      writer.mapHeader(2)
      writer.uint(keyOp); writer.uint(opPeripheralStateChanged)
      writer.uint(keyManagerState); writer.uint(state)
    case let .readRequest(requestId, serviceUUID, characteristicUUID, offset, centralId):
      writer.mapHeader(6)
      writer.uint(keyOp); writer.uint(opReadRequest)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUID); writer.text(characteristicUUID)
      writer.uint(keyRequestId); writer.uint(requestId)
      writer.uint(keyATTOffset); writer.uint(offset)
      writer.uint(keyCentralId); writer.bytes(centralId)
    case let .writeRequest(requestId, serviceUUID, characteristicUUID, value, offset, centralId):
      writer.mapHeader(7)
      writer.uint(keyOp); writer.uint(opWriteRequest)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUID); writer.text(characteristicUUID)
      writer.uint(keyValue); writer.bytes(value)
      writer.uint(keyRequestId); writer.uint(requestId)
      writer.uint(keyATTOffset); writer.uint(offset)
      writer.uint(keyCentralId); writer.bytes(centralId)
    case let .subscribed(serviceUUID, characteristicUUID, centralId, mtu):
      writer.mapHeader(5)
      writer.uint(keyOp); writer.uint(opSubscribed)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUID); writer.text(characteristicUUID)
      writer.uint(keyCentralId); writer.bytes(centralId)
      writer.uint(keyMTU); writer.uint(mtu)
    case let .unsubscribed(serviceUUID, characteristicUUID, centralId):
      writer.mapHeader(4)
      writer.uint(keyOp); writer.uint(opUnsubscribed)
      writer.uint(keyServiceUUID); writer.text(serviceUUID)
      writer.uint(keyCharacteristicUUID); writer.text(characteristicUUID)
      writer.uint(keyCentralId); writer.bytes(centralId)
    case .readyToUpdate:
      writer.mapHeader(1)
      writer.uint(keyOp); writer.uint(opReadyToUpdate)
    }
    return writer.data
  }

  /// Decode an event payload, dispatching on the op in key 0.
  ///
  /// - Throws: `ProtocolError` when the bytes are not canonical CBOR, a
  ///   required field is absent, or the op is not an event op.
  public static func decodeEvent(_ payload: Data) throws -> Event {
    let map = try CBORMap(decoding: payload)
    switch try map.uint(keyOp) {
    case opDiscovered:
      let advertisement = Advertisement(
        localName: map.optionalText(keyLocalName),
        serviceUUIDs: map.optionalTextArray(keyAdvertisedServiceUUIDs),
        txPower: map.optionalInt(keyTxPower),
        manufacturerData: map.optionalBytes(keyManufacturerData)
      )
      return try .discovered(peripheralId: map.bytes(keyPeripheralId),
                             advertisement: advertisement, rssi: map.int(keyRSSI))
    case opCharValue:
      return try .characteristicValue(peripheralId: map.bytes(keyPeripheralId),
                                      serviceUUID: map.text(keyServiceUUID),
                                      characteristicUUID: map.text(keyCharacteristicUUID),
                                      value: map.bytes(keyValue))
    case opDisconnectedEvent:
      return try .peripheralDisconnected(peripheralId: map.bytes(keyPeripheralId),
                                         errorCode: map.optionalInt(keyErrorCode))
    case opCentralStateChanged:
      return try .centralStateChanged(state: map.uint(keyManagerState))
    case opPeripheralStateChanged:
      return try .peripheralStateChanged(state: map.uint(keyManagerState))
    case opReadRequest:
      return try .readRequest(requestId: map.uint(keyRequestId),
                              serviceUUID: map.text(keyServiceUUID),
                              characteristicUUID: map.text(keyCharacteristicUUID),
                              offset: map.uint(keyATTOffset),
                              centralId: map.bytes(keyCentralId))
    case opWriteRequest:
      return try .writeRequest(requestId: map.uint(keyRequestId),
                               serviceUUID: map.text(keyServiceUUID),
                               characteristicUUID: map.text(keyCharacteristicUUID),
                               value: map.bytes(keyValue),
                               offset: map.uint(keyATTOffset),
                               centralId: map.bytes(keyCentralId))
    case opSubscribed:
      return try .subscribed(serviceUUID: map.text(keyServiceUUID),
                             characteristicUUID: map.text(keyCharacteristicUUID),
                             centralId: map.bytes(keyCentralId), mtu: map.uint(keyMTU))
    case opUnsubscribed:
      return try .unsubscribed(serviceUUID: map.text(keyServiceUUID),
                               characteristicUUID: map.text(keyCharacteristicUUID),
                               centralId: map.bytes(keyCentralId))
    case opReadyToUpdate:
      return .readyToUpdate
    case let other:
      throw ProtocolError.badOpcode(other)
    }
  }
}
