// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation

/// The subset of CBOR (RFC 8949) the protocol uses: unsigned integers, negative
/// integers, byte strings, text strings, definite-length arrays of text strings,
/// and definite-length maps keyed by unsigned integers. Hand-written rather than
/// pulled from a dependency because the surface is this small and both ends, this
/// codec and the C one, must agree byte for byte.
enum CBORValue: Equatable {
  case uint(UInt64)
  case negInt(UInt64)
  case bytes(Data)
  case text(String)
  case textArray([String])
}

struct CBORWriter {
  private(set) var data = Data()

  mutating func mapHeader(_ count: Int) {
    writeHead(major: 5, value: UInt64(count))
  }

  mutating func uint(_ value: UInt64) {
    writeHead(major: 0, value: value)
  }

  /// A signed integer: major 0 for non-negative, major 1 for negative, where
  /// the negative `n` is encoded as the argument `-1 - n` (RFC 8949).
  mutating func int(_ value: Int64) {
    if value >= 0 {
      writeHead(major: 0, value: UInt64(value))
    } else {
      writeHead(major: 1, value: UInt64(-1 - value))
    }
  }

  mutating func bytes(_ value: Data) {
    writeHead(major: 2, value: UInt64(value.count))
    data.append(value)
  }

  mutating func text(_ value: String) {
    let utf8 = Data(value.utf8)
    writeHead(major: 3, value: UInt64(utf8.count))
    data.append(utf8)
  }

  /// A definite-length array of text strings: the array header, then each
  /// element as a text string, all in shortest form. The BLE message set carries
  /// UUID lists this way, the one place an array is needed.
  mutating func textArray(_ values: [String]) {
    writeHead(major: 4, value: UInt64(values.count))
    for value in values {
      text(value)
    }
  }

  /// Emit a major type and an argument in the shortest form, which is what
  /// canonical CBOR requires.
  private mutating func writeHead(major: UInt8, value: UInt64) {
    let tag = major << 5
    switch value {
    case 0 ..< 24:
      data.append(tag | UInt8(value))
    case 24 ..< 0x100:
      data.append(tag | 24)
      data.append(UInt8(value))
    case 0x100 ..< 0x10000:
      data.append(tag | 25)
      appendBigEndian(value, bytes: 2)
    case 0x10000 ..< 0x1_0000_0000:
      data.append(tag | 26)
      appendBigEndian(value, bytes: 4)
    default:
      data.append(tag | 27)
      appendBigEndian(value, bytes: 8)
    }
  }

  private mutating func appendBigEndian(_ value: UInt64, bytes: Int) {
    for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
      data.append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
  }
}

struct CBORReader {
  private let data: Data
  private var offset: Int

  init(_ data: Data) {
    self.data = data
    offset = 0
  }

  var isAtEnd: Bool {
    offset == data.count
  }

  func expectEnd() throws {
    guard isAtEnd else { throw ProtocolError.trailingBytes }
  }

  mutating func mapHeader() throws -> Int {
    let head = try byte()
    guard head >> 5 == 5 else { throw ProtocolError.typeMismatch }
    return try lengthArgument(head & 0x1F)
  }

  mutating func uint() throws -> UInt64 {
    let head = try byte()
    guard head >> 5 == 0 else { throw ProtocolError.typeMismatch }
    return try argument(head & 0x1F)
  }

  /// Read one value of whichever supported type comes next.
  mutating func value() throws -> CBORValue {
    let head = try byte()
    let major = head >> 5
    let additional = head & 0x1F
    switch major {
    case 0:
      return try .uint(argument(additional))
    case 1:
      return try .negInt(argument(additional))
    case 2:
      return try .bytes(take(lengthArgument(additional)))
    case 3:
      return try .text(String(decoding: take(lengthArgument(additional)), as: UTF8.self))
    case 4:
      let count = try lengthArgument(additional)
      var elements: [String] = []
      elements.reserveCapacity(count)
      for _ in 0 ..< count {
        let elementHead = try byte()
        guard elementHead >> 5 == 3 else { throw ProtocolError.typeMismatch }
        let length = try lengthArgument(elementHead & 0x1F)
        try elements.append(String(decoding: take(length), as: UTF8.self))
      }
      return .textArray(elements)
    default:
      throw ProtocolError.typeMismatch
    }
  }

  private mutating func byte() throws -> UInt8 {
    guard offset < data.count else { throw ProtocolError.truncated }
    let value = data[data.startIndex + offset]
    offset += 1
    return value
  }

  private mutating func take(_ count: Int) throws -> Data {
    guard count >= 0, count <= data.count - offset else { throw ProtocolError.truncated }
    let start = data.startIndex + offset
    let slice = data[start ..< start + count]
    offset += count
    return Data(slice)
  }

  /// Decode a length or count argument and bound it by the remaining input
  /// before any `Int` conversion. A hostile 64-bit length must throw, never
  /// trap: this runs on unauthenticated bytes, before the token gate.
  private mutating func lengthArgument(_ additional: UInt8) throws -> Int {
    let value = try argument(additional)
    guard value <= UInt64(data.count - offset) else { throw ProtocolError.truncated }
    return Int(value)
  }

  /// Decode the argument that follows a head byte. Indefinite length and the
  /// reserved additional-info values are rejected.
  private mutating func argument(_ additional: UInt8) throws -> UInt64 {
    switch additional {
    case 0 ..< 24:
      return UInt64(additional)
    case 24:
      let value = try UInt64(byte())
      guard value >= 24 else { throw ProtocolError.nonCanonical }
      return value
    case 25:
      let value = try bigEndian(2)
      guard value > 0xFF else { throw ProtocolError.nonCanonical }
      return value
    case 26:
      let value = try bigEndian(4)
      guard value > 0xFFFF else { throw ProtocolError.nonCanonical }
      return value
    case 27:
      let value = try bigEndian(8)
      guard value > 0xFFFF_FFFF else { throw ProtocolError.nonCanonical }
      return value
    default:
      throw ProtocolError.malformed
    }
  }

  private mutating func bigEndian(_ count: Int) throws -> UInt64 {
    var value: UInt64 = 0
    for byte in try take(count) {
      value = (value << 8) | UInt64(byte)
    }
    return value
  }
}

/// A decoded message map, with type-checked accessors per key.
struct CBORMap {
  private let entries: [UInt64: CBORValue]

  /// Read a definite-length map of `uint => value` pairs, with no bytes left
  /// over.
  init(decoding payload: Data) throws {
    var reader = CBORReader(payload)
    let count = try reader.mapHeader()
    var entries: [UInt64: CBORValue] = [:]
    for _ in 0 ..< count {
      let key = try reader.uint()
      guard entries[key] == nil else { throw ProtocolError.duplicateKey(key) }
      entries[key] = try reader.value()
    }
    try reader.expectEnd()
    self.entries = entries
  }

  func uint(_ key: UInt64) throws -> UInt64 {
    guard case let .uint(value)? = entries[key] else { throw ProtocolError.missingField(key) }
    return value
  }

  /// A uint if present and of the right type, else nil. For optional keys.
  func optionalUint(_ key: UInt64) -> UInt64? {
    if case let .uint(value)? = entries[key] { return value }
    return nil
  }

  /// A signed integer if present and of an integer type, else nil. For optional keys.
  func optionalInt(_ key: UInt64) -> Int64? {
    switch entries[key] {
    case let .uint(value)?:
      return value <= UInt64(Int64.max) ? Int64(value) : nil
    case let .negInt(argument)?:
      return argument <= UInt64(Int64.max) ? -1 - Int64(argument) : nil
    default:
      return nil
    }
  }

  /// A text string if present and of the right type, else nil. For optional keys.
  func optionalText(_ key: UInt64) -> String? {
    if case let .text(value)? = entries[key] { return value }
    return nil
  }

  /// A byte string if present and of the right type, else nil. For optional keys.
  func optionalBytes(_ key: UInt64) -> Data? {
    if case let .bytes(value)? = entries[key] { return value }
    return nil
  }

  /// A text-string array if present and of the right type, else nil. For optional keys.
  func optionalTextArray(_ key: UInt64) -> [String]? {
    if case let .textArray(value)? = entries[key] { return value }
    return nil
  }

  /// A signed integer. Values outside `Int64` throw rather than trap: the
  /// bytes are unauthenticated, so an oversized argument is hostile input,
  /// not a programming error.
  func int(_ key: UInt64) throws -> Int64 {
    switch entries[key] {
    case let .uint(value)?:
      guard value <= UInt64(Int64.max) else { throw ProtocolError.malformed }
      return Int64(value)
    case let .negInt(argument)?:
      guard argument <= UInt64(Int64.max) else { throw ProtocolError.malformed }
      return -1 - Int64(argument)
    default: throw ProtocolError.missingField(key)
    }
  }

  func bytes(_ key: UInt64) throws -> Data {
    guard case let .bytes(value)? = entries[key] else { throw ProtocolError.missingField(key) }
    return value
  }

  func text(_ key: UInt64) throws -> String {
    guard case let .text(value)? = entries[key] else { throw ProtocolError.missingField(key) }
    return value
  }

  func textArray(_ key: UInt64) throws -> [String] {
    guard case let .textArray(value)? = entries[key] else {
      throw ProtocolError.missingField(key)
    }
    return value
  }
}
