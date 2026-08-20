import Foundation
import XCTest
@testable import SharedCore

final class TunnelDiagnosticsStoreTests: XCTestCase {
    func testAppendsAndSnapshotsEntries() {
        let (store, userDefaults, suiteName) = makeStore()

        store.append("DNS example.com via local ok")
        store.append("TCP direct 1.0.1.8:443 host=-")

        let lines = store.snapshot()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("DNS example.com via local ok"))
        XCTAssertTrue(lines[1].contains("TCP direct 1.0.1.8:443 host=-"))

        userDefaults.removePersistentDomain(forName: suiteName)
    }

    func testTrimsOldestEntriesBeyondCapacity() {
        let (store, userDefaults, suiteName) = makeStore(capacity: 3)

        for index in 0..<5 {
            store.append("event \(index)")
        }

        let lines = store.snapshot()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("event 2"))
        XCTAssertTrue(lines[2].contains("event 4"))

        userDefaults.removePersistentDomain(forName: suiteName)
    }

    func testClearRemovesAllEntries() {
        let (store, userDefaults, suiteName) = makeStore()

        store.append("event")
        store.clear()

        XCTAssertEqual(store.snapshot(), [])

        userDefaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore(
        capacity: Int = 200
    ) -> (TunnelDiagnosticsStore, UserDefaults, String) {
        let suiteName = "TunnelDiagnosticsStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return (TunnelDiagnosticsStore(userDefaults: userDefaults, capacity: capacity), userDefaults, suiteName)
    }
}
