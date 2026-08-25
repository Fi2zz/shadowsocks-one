import XCTest
@testable import SharedCore

final class BrowserTabStoreTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tab-store-tests-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "tab-store-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripsTabsAndActiveID() throws {
        let store = try BrowserTabStore(directory: directory, defaults: defaults)
        let tab = BrowserTab(title: "示例", url: URL(string: "https://example.com"))
        try store.save([tab], activeID: tab.id)

        let reloaded = try BrowserTabStore(directory: directory, defaults: defaults)
        XCTAssertEqual(reloaded.loadTabs(), [tab])
        XCTAssertEqual(reloaded.loadActiveID(), tab.id)
    }

    func testLoadReturnsEmptyWhenNothingSaved() throws {
        let store = try BrowserTabStore(directory: directory, defaults: defaults)
        XCTAssertEqual(store.loadTabs(), [])
        XCTAssertNil(store.loadActiveID())
    }

    func testStateSaveLoadAndDelete() throws {
        let store = try BrowserTabStore(directory: directory, defaults: defaults)
        let tab = BrowserTab(title: "t", url: nil)
        let payload = Data("interaction-state".utf8)

        store.saveState(payload, for: tab)
        XCTAssertEqual(store.loadState(for: tab), payload)

        store.saveState(nil, for: tab)
        XCTAssertNil(store.loadState(for: tab))
    }

    func testDeleteFilesRemovesStateAndSnapshot() throws {
        let store = try BrowserTabStore(directory: directory, defaults: defaults)
        let tab = BrowserTab(title: "t", url: nil)
        store.saveState(Data("x".utf8), for: tab)
        try Data("jpg".utf8).write(to: store.snapshotURL(for: tab))

        store.deleteFiles(for: tab)

        XCTAssertNil(store.loadState(for: tab))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshotURL(for: tab).path))
    }
}
