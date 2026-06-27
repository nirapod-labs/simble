// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation

#if canImport(Security)
  import Security
#endif

/// The per-session capability token: 32 random bytes that gate every request to
/// the helper (see SECURITY.md). The bytes are the credential; the hex form, in the
/// scheme environment, is only transport.
public struct CapabilityToken: Equatable, Sendable {
  /// Token length in bytes; the gate compares exactly this many.
  public static let byteCount = 32
  /// The raw token bytes, the actual credential.
  public let bytes: Data

  /// Mint a fresh token from the system CSPRNG.
  public init() {
    var raw = Data(count: Self.byteCount)
    let status = raw.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, Self.byteCount, $0.baseAddress!)
    }
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    bytes = raw
  }

  /// Wrap raw bytes, for example decoded from a request. Nil unless 32 bytes.
  public init?(bytes: Data) {
    guard bytes.count == Self.byteCount else { return nil }
    self.bytes = bytes
  }

  /// Parse the lowercase-hex transport form. Nil on wrong length or non-hex.
  public init?(hex: String) {
    guard hex.utf8.count == Self.byteCount * 2 else { return nil }
    var raw = Data(capacity: Self.byteCount)
    var index = hex.startIndex
    for _ in 0 ..< Self.byteCount {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
      raw.append(byte)
      index = next
    }
    bytes = raw
  }

  /// Lowercase hex, the environment transport form.
  public var hex: String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}

/// Validates a presented token against the session token. The comparison is constant
/// time over the fixed 32 bytes: it never branches on the contents, so it leaks
/// nothing through timing about where two tokens diverge.
public struct AuthGate: Sendable {
  private let session: CapabilityToken

  /// Bind the gate to this session's token.
  public init(session: CapabilityToken) {
    self.session = session
  }

  /// Whether the presented token matches the session token, compared in constant
  /// time over the fixed 32 bytes.
  public func accepts(_ presented: CapabilityToken) -> Bool {
    session.bytes.withUnsafeBytes { (sessionBytes: UnsafeRawBufferPointer) -> Bool in
      presented.bytes.withUnsafeBytes { (presentedBytes: UnsafeRawBufferPointer) -> Bool in
        var difference: UInt8 = 0
        for i in 0 ..< CapabilityToken.byteCount {
          difference |= sessionBytes[i] ^ presentedBytes[i]
        }
        return difference == 0
      }
    }
  }
}
