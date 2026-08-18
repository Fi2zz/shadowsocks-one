import Foundation
import XCTest
@testable import SharedCore

final class TunnelRuntimeStatusStoreTests: XCTestCase {
    func testConsumesStoredFailureDetailOnlyOnce() {
        let suiteName = "TunnelRuntimeStatusStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let store = TunnelRuntimeStatusStore(userDefaults: userDefaults)
        store.saveLastFailureDetail("dns bootstrap failed")

        XCTAssertEqual(store.consumeLastFailureDetail(), "dns bootstrap failed")
        XCTAssertNil(store.consumeLastFailureDetail())

        userDefaults.removePersistentDomain(forName: suiteName)
    }

    func testEmptyFailureDetailClearsStoredValue() {
        let suiteName = "TunnelRuntimeStatusStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let store = TunnelRuntimeStatusStore(userDefaults: userDefaults)
        store.saveLastFailureDetail("relay failed")
        store.saveLastFailureDetail("   ")

        XCTAssertNil(store.consumeLastFailureDetail())

        userDefaults.removePersistentDomain(forName: suiteName)
    }
}
