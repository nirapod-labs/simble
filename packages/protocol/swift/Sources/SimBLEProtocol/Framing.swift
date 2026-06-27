// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation

/// The length prefix that wraps each CBOR payload on the wire (see `SPEC.md`).
/// The socket read loop (read four bytes, then that many) lives in the helper and
/// the interposer; this provides the two pure halves they share.
public enum Framing {
  /// Largest frame either end accepts: 1 MiB, matching the C codec's SIMBLE_MAX_FRAME.
  public static let maxFrame = 1 << 20

  /// Prefix a payload with its big-endian `u32` length, ready to write.
  public static func frame(_ payload: Data) -> Data {
    precondition(payload.count <= maxFrame, "payload exceeds MAX_FRAME")
    let length = UInt32(payload.count)
    var out = Data(capacity: payload.count + 4)
    out.append(UInt8((length >> 24) & 0xFF))
    out.append(UInt8((length >> 16) & 0xFF))
    out.append(UInt8((length >> 8) & 0xFF))
    out.append(UInt8(length & 0xFF))
    out.append(payload)
    return out
  }

  /// Decode a 4-byte length prefix into the payload size that follows, refusing
  /// anything past `maxFrame` so a peer cannot make the reader allocate.
  public static func payloadLength(_ prefix: Data) throws -> Int {
    guard prefix.count == 4 else { throw ProtocolError.truncated }
    let i = prefix.startIndex
    let length = (Int(prefix[i]) << 24)
      | (Int(prefix[i + 1]) << 16)
      | (Int(prefix[i + 2]) << 8)
      | Int(prefix[i + 3])
    guard length <= maxFrame else { throw ProtocolError.frameTooLarge(length) }
    return length
  }
}
