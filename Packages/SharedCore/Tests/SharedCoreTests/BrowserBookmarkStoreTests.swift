import XCTest
@testable import SharedCore

final class BrowserBookmarkStoreTests: XCTestCase {
    private var store: BrowserBookmarkStore!
    private var jsonURL: URL!

    override func setUpWithError() throws {
        jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmarks-\(UUID().uuidString).json")
        store = BrowserBookmarkStore(jsonURL: jsonURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: jsonURL)
    }

    private func entry(_ path: String, title: String = "t") -> BrowserBookmarkEntry {
        BrowserBookmarkEntry(url: URL(string: "https://\(path)")!, title: title)
    }

    func testLoadReturnsEmptyWhenFileMissing() throws {
        XCTAssertEqual(try store.loadEntries(), [])
    }

    func testAppendInsertsNewestFirst() throws {
        try store.append(entry("a.com"))
        try store.append(entry("b.com", title: "B"))

        let entries = try store.loadEntries()
        XCTAssertEqual(entries.map(\.url.host), ["b.com", "a.com"])
        XCTAssertEqual(entries.first?.title, "B")
    }

    func testAppendSameURLUpdatesTitleInPlace() throws {
        try store.append(entry("a.com", title: "旧标题"))
        try store.append(entry("a.com", title: "新标题"))

        let entries = try store.loadEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "新标题")
    }

    func testRemoveDeletesOnlyTargetEntry() throws {
        try store.append(entry("a.com"))
        let kept = entry("b.com", title: "keep")
        try store.append(kept)

        try store.remove(id: kept.id)

        let entries = try store.loadEntries()
        XCTAssertEqual(entries.map(\.url.host), ["a.com"])
    }
}
