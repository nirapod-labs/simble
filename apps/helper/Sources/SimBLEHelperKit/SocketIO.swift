// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLEProtocol

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// A socket-level failure distinct from a protocol decode failure.
enum SocketError: Error, Equatable {
  /// The peer closed mid-message; never surfaced as a partial read.
  case closed
  /// A read deadline elapsed at a frame boundary, nothing pending. Benign for an idle
  /// event-stream connection that legitimately sends no requests.
  case idleTimeout
  /// An OS call failed; the message is the errno text.
  case system(String)
}

/// Read exactly `count` bytes, looping over short reads, or throw. A peer that closes
/// mid-message is `closed`, not a partial read.
func readFull(_ fd: Int32, _ count: Int) throws -> Data {
  guard count > 0 else { return Data() }
  var buffer = Data(count: count)
  var read = 0
  try buffer.withUnsafeMutableBytes { raw in
    let base = raw.baseAddress!
    while read < count {
      let n = recv(fd, base + read, count - read, 0)
      if n == 0 { throw SocketError.closed }
      if n < 0 { throw SocketError.system(String(cString: strerror(errno))) }
      read += n
    }
  }
  return buffer
}

/// Write all of `data`, looping over short writes, or throw.
func writeFull(_ fd: Int32, _ data: Data) throws {
  guard !data.isEmpty else { return }
  try data.withUnsafeBytes { raw in
    let base = raw.baseAddress!
    var written = 0
    while written < data.count {
      let n = send(fd, base + written, data.count - written, 0)
      if n <= 0 { throw SocketError.system(String(cString: strerror(errno))) }
      written += n
    }
  }
}

/// Read one length-prefixed frame and return its CBOR payload. A length past the 1 MiB
/// cap is refused before any allocation.
func readFrame(_ fd: Int32) throws -> Data {
  let length = try Framing.payloadLength(readHeader(fd))
  return try readFull(fd, length)
}

/// Read the 4-byte frame header. A read deadline with no header byte yet is `idleTimeout`,
/// not a failure, so an idle event-stream connection survives. A timeout mid-header is real.
func readHeader(_ fd: Int32) throws -> Data {
  var buffer = Data(count: 4)
  var read = 0
  try buffer.withUnsafeMutableBytes { raw in
    let base = raw.baseAddress!
    while read < 4 {
      let n = recv(fd, base + read, 4 - read, 0)
      if n == 0 { throw SocketError.closed }
      if n < 0 {
        if read == 0, errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.idleTimeout }
        throw SocketError.system(String(cString: strerror(errno)))
      }
      read += n
    }
  }
  return buffer
}

/// Frame a CBOR payload and write it.
func writeFrame(_ fd: Int32, _ payload: Data) throws {
  try writeFull(fd, Framing.frame(payload))
}

/// The errno text for the current thread, for a socket error message.
func errnoText() -> String {
  String(cString: strerror(errno))
}
