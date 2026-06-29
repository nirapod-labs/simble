// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
import SimBLEProtocol

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// A loopback TCP server bound to `127.0.0.1`. It accepts connections on a background
/// thread, serves each connection on its own thread, answers framed CBOR requests
/// through the router (which authenticates every request by its capability token), and
/// streams the central service's events back to the connected client as event frames.
///
/// Loopback TCP, not a Unix socket, because the simulator shares the host network stack
/// but virtualizes its filesystem, so a host socket file is not reachable from a
/// simulated app.
public final class LoopbackListener: @unchecked Sendable {
  /// Idle deadline on an accepted connection's reads and writes, so a peer that connects
  /// and stalls cannot park a serve thread forever.
  private static let connectionIdleTimeout = timeval(tv_sec: 30, tv_usec: 0)

  private let router: RequestRouter
  private let lifecycleLock = NSLock()
  private var listenFD: Int32 = -1
  private var worker: Thread?
  private var running = false
  private let acceptExited = DispatchSemaphore(value: 0)

  /// The bound port, valid after `start`. Zero before then.
  public private(set) var port: UInt16 = 0

  /// Build the listener around the router that answers each request and supplies events.
  public init(router: RequestRouter) {
    self.router = router
  }

  /// Bind, listen, and start accepting. Pass `0` to take an ephemeral port, then read the
  /// chosen port from `port`.
  public func start(port requestedPort: UInt16 = 0) throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.system("socket: \(errnoText())") }

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = requestedPort.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { close(fd); throw SocketError.system("bind: \(errnoText())") }
    guard listen(fd, 16) == 0 else { close(fd); throw SocketError.system("listen: \(errnoText())") }

    let worker = Thread { [weak self] in self?.acceptLoop() }
    worker.stackSize = 1 << 20
    worker.name = "simble.loopback"

    lifecycleLock.lock()
    guard !running else {
      lifecycleLock.unlock()
      close(fd)
      throw SocketError.system("already started")
    }
    port = boundPort(fd)
    listenFD = fd
    running = true
    self.worker = worker
    lifecycleLock.unlock()

    worker.start()
  }

  /// Stop accepting and close the listening socket. Synchronous: it wakes the accept loop
  /// and waits for it to exit. In-flight connections finish on their own threads.
  public func stop() {
    lifecycleLock.lock()
    let wasRunning = running
    running = false
    let fd = listenFD
    listenFD = -1
    lifecycleLock.unlock()

    if fd >= 0 {
      shutdown(fd, SHUT_RDWR)
      close(fd)
    }
    if wasRunning {
      _ = acceptExited.wait(timeout: .now() + 2)
    }
  }

  private func acceptLoop() {
    defer { acceptExited.signal() }
    while isRunning() {
      let fd = currentListenFD()
      if fd < 0 { break }
      let client = accept(fd, nil, nil)
      if client < 0 {
        if isRunning() { continue }
        break
      }
      var deadline = Self.connectionIdleTimeout
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
      setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
      let connection = Thread { [weak self] in
        guard let self else {
          close(client)
          return
        }
        self.serve(client)
      }
      connection.stackSize = 1 << 20
      connection.name = "simble.connection"
      connection.start()
    }
  }

  private func isRunning() -> Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    return running
  }

  private func currentListenFD() -> Int32 {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    return listenFD
  }

  private func serve(_ fd: Int32) {
    // One write lock per connection, so a streamed event frame and a response frame never
    // interleave their bytes on the same socket. The router writes events through `emit`.
    let writeLock = NSLock()
    let emit: @Sendable (Event) -> Void = { event in
      writeLock.lock()
      defer { writeLock.unlock() }
      try? writeFrame(fd, Wire.encode(event))
    }
    let sinkID = router.attachEventSink(emit)
    defer {
      router.detachEventSink(sinkID)
      close(fd)
    }
    while true {
      do {
        let response = try router.respond(toPayload: readFrame(fd))
        writeLock.lock()
        do { try writeFrame(fd, Wire.encode(response)) }
        catch { writeLock.unlock(); return }
        writeLock.unlock()
      } catch {
        // Peer closed, or a malformed frame: drop this connection.
        return
      }
    }
  }

  private func boundPort(_ fd: Int32) -> UInt16 {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        _ = getsockname(fd, $0, &length)
      }
    }
    return UInt16(bigEndian: address.sin_port)
  }
}
