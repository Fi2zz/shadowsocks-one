import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksOnePacketTunnel

final class UDPSessionStoreTests: XCTestCase {
    func testCreatesThenReusesSession() throws {
        let store = UDPSessionStore()
        let factory = UDPRelayFactorySpy()
        let key = makeFlowKey(destination: "1.1.1.1")

        let first = try store.session(for: key) { try factory.makeRelay(key: key) }
        let second = try store.session(for: key) { try factory.makeRelay(key: key) }

        XCTAssertTrue(first.sessionCreated)
        XCTAssertFalse(second.sessionCreated)
        XCTAssertEqual(factory.createdRelayCount, 1)
    }

    func testEvictsExpiredSessionsOnNextInsert() throws {
        var current = Date(timeIntervalSince1970: 1_000)
        let store = UDPSessionStore(idleTimeout: 60, now: { current })
        let factory = UDPRelayFactorySpy()
        let staleKey = makeFlowKey(destination: "1.1.1.1")

        _ = try store.session(for: staleKey) { try factory.makeRelay(key: staleKey) }
        current = current.addingTimeInterval(120)

        let freshKey = makeFlowKey(destination: "8.8.8.8")
        let result = try store.session(for: freshKey) { try factory.makeRelay(key: freshKey) }

        XCTAssertEqual(result.evictedRelays.count, 1)
        XCTAssertNil(store.removeRelay(for: staleKey))
    }

    func testKeepsActiveSessionBeyondIdleTimeout() throws {
        var current = Date(timeIntervalSince1970: 1_000)
        let store = UDPSessionStore(idleTimeout: 60, now: { current })
        let factory = UDPRelayFactorySpy()
        let activeKey = makeFlowKey(destination: "1.1.1.1")

        _ = try store.session(for: activeKey) { try factory.makeRelay(key: activeKey) }
        current = current.addingTimeInterval(120)
        let reused = try store.session(for: activeKey) { try factory.makeRelay(key: activeKey) }

        current = current.addingTimeInterval(30)
        let otherKey = makeFlowKey(destination: "8.8.8.8")
        let result = try store.session(for: otherKey) { try factory.makeRelay(key: otherKey) }

        XCTAssertFalse(reused.sessionCreated)
        XCTAssertTrue(result.evictedRelays.isEmpty)
    }

    func testEvictsOldestWhenOverCapacity() throws {
        var current = Date(timeIntervalSince1970: 1_000)
        let store = UDPSessionStore(capacity: 1, idleTimeout: 3_600, now: { current })
        let factory = UDPRelayFactorySpy()
        let oldestKey = makeFlowKey(destination: "1.1.1.1")

        _ = try store.session(for: oldestKey) { try factory.makeRelay(key: oldestKey) }
        current = current.addingTimeInterval(10)
        let newestKey = makeFlowKey(destination: "8.8.8.8")
        let result = try store.session(for: newestKey) { try factory.makeRelay(key: newestKey) }

        XCTAssertEqual(result.evictedRelays.count, 1)
        XCTAssertNil(store.removeRelay(for: oldestKey))
        XCTAssertNotNil(store.removeRelay(for: newestKey))
    }

    func testRemoveAllRelays() throws {
        let store = UDPSessionStore()
        let factory = UDPRelayFactorySpy()
        let firstKey = makeFlowKey(destination: "1.1.1.1")
        let secondKey = makeFlowKey(destination: "8.8.8.8")

        _ = try store.session(for: firstKey) { try factory.makeRelay(key: firstKey) }
        _ = try store.session(for: secondKey) { try factory.makeRelay(key: secondKey) }

        XCTAssertEqual(store.removeAllRelays().count, 2)
        XCTAssertEqual(store.removeAllRelays().count, 0)
    }

    private func makeFlowKey(destination: String) -> UDPFlowKey {
        try! UDPFlowKey(
            packet: makeUDPPacket(destination: destination, destinationPort: 443, payload: "x")
        )
    }
}
