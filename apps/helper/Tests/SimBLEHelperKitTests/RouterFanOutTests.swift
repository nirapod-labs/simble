// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation
@testable import SimBLEHelperKit
import SimBLEHostCore
import SimBLEProtocol
import XCTest

/// The router fans one backend event out to every registered sink, and a detached sink
/// stops receiving. Driven through a fake backend with no radio.
final class RouterFanOutTests: XCTestCase {
  private let peripheralId = Data([0xDE, 0xAD, 0xBE, 0xEF])

  private let discovery = CentralBackendEvent.discovered(
    peripheralId: Data([0xDE, 0xAD, 0xBE, 0xEF]), localName: "Sensor",
    serviceUUIDs: ["180D"], txPower: nil, manufacturerData: nil, rssi: -40
  )

  private var expectedEvent: Event {
    .discovered(peripheralId: peripheralId,
                advertisement: Advertisement(localName: "Sensor", serviceUUIDs: ["180D"]),
                rssi: -40)
  }

  private func router(backend: FakeCentralBackend) -> RequestRouter {
    RequestRouter(service: CentralService(backend: backend),
                  peripheralService: PeripheralService(backend: FakePeripheralBackend()),
                  gate: AuthGate(session: CapabilityToken()))
  }

  /// A recorder of the events a sink receives, safe to read after the emit returns.
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Event] = []

    var sink: @Sendable (Event) -> Void {
      { event in self.lock.lock(); self.events.append(event); self.lock.unlock() }
    }

    var received: [Event] {
      lock.lock(); defer { lock.unlock() }; return events
    }
  }

  func testEventFansOutToEverySink() {
    let backend = FakeCentralBackend()
    let router = router(backend: backend)
    let first = Recorder()
    let second = Recorder()
    _ = router.attachEventSink(first.sink)
    _ = router.attachEventSink(second.sink)

    backend.emit(discovery)

    XCTAssertEqual(first.received, [expectedEvent])
    XCTAssertEqual(second.received, [expectedEvent])
  }

  func testDetachedSinkStopsReceiving() {
    let backend = FakeCentralBackend()
    let router = router(backend: backend)
    let kept = Recorder()
    let dropped = Recorder()
    _ = router.attachEventSink(kept.sink)
    let droppedID = router.attachEventSink(dropped.sink)

    router.detachEventSink(droppedID)
    backend.emit(discovery)

    XCTAssertEqual(kept.received, [expectedEvent])
    XCTAssertEqual(dropped.received, [])
  }
}
