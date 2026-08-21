import XCTest
@testable import SharedCore

final class BrowserHistoryStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: BrowserHistoryStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = BrowserHistoryStore(jsonURL: tempDirectory.appendingPathComponent("history.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testLoadFromMissingFileReturnsEmpty() throws {
        XCTAssertEqual(try store.loadEntries(), [])
    }

    func testAppendInsertsNewestFirst() throws {
        try store.append(makeEntry(url: "https://a.com"))
        try store.append(makeEntry(url: "https://b.com"))

        let entries = try store.loadEntries()
        XCTAssertEqual(entries.map(\.url.absoluteString), ["https://b.com", "https://a.com"])
    }

    func testAppendSameURLMovesEntryToFront() throws {
        try store.append(makeEntry(url: "https://a.com"))
        try store.append(makeEntry(url: "https://b.com"))
        try store.append(makeEntry(url: "https://a.com", title: "新标题"))

        let entries = try store.loadEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.title, "新标题")
    }

    func testAppendCapsEntryCount() throws {
        for index in 0..<(BrowserHistoryStore.maxEntryCount + 10) {
            try store.append(makeEntry(url: "https://example.com/\(index)"))
        }

        XCTAssertEqual(try store.loadEntries().count, BrowserHistoryStore.maxEntryCount)
    }

    func testClearRemovesAllEntries() throws {
        try store.append(makeEntry(url: "https://a.com"))
        try store.clear()

        XCTAssertEqual(try store.loadEntries(), [])
    }

    private func makeEntry(url: String, title: String = "") -> BrowserHistoryEntry {
        BrowserHistoryEntry(url: URL(string: url)!, title: title)
    }
}
