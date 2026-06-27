// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLEProtocol

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// A loopback connection to the helper held open across frames: connect, send
/// requests, read responses, and read the events the helper streams back. The
/// interposer's C transport mirrors this; the helper's own tests and `simblectl`
/// use this Swift one.
public final class LoopbackClient: @unchecked Sendable {
  private let fd: Int32

  /// The helper's bound port on 127.0.0.1.
  public let port: UInt16

  /// Open a connection to a helper's port.
  ///
  /// - Throws: `SocketError` on a connect failure.
  public init(port: UInt16) throws {
    self.port = port
    fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.system("socket: \(errnoText())") }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else {
      close(fd)
      throw SocketError.system("connect: \(errnoText())")
    }

    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }

  deinit { close(fd) }

  /// Send one request and read its response on this connection.
  ///
  /// - Parameters:
  ///   - request: The request to encode and send.
  ///   - token: The session capability token, carried in key 7.
  ///   - appID: An app id for HELLO, carried in key 14 when set.
  /// - Returns: The decoded response, which may be `.failure`.
  /// - Throws: `SocketError` on an I/O failure, `ProtocolError` on a malformed response.
  public func send(_ request: Request, token: CapabilityToken, appID: String? = nil) throws
    -> Response
  {
    try writeFrame(fd, Wire.encode(request, token: token.bytes, appID: appID))
    return try Wire.decodeResponse(readFrame(fd))
  }

  /// Read the next frame as an event, for a test reading the events the helper streams.
  ///
  /// - Throws: `SocketError` on an I/O failure, `ProtocolError` on a non-event frame.
  public func receiveEvent() throws -> Event {
    try Wire.decodeEvent(readFrame(fd))
  }
}
