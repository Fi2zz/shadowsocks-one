import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksOne

@MainActor
final class IPListViewModelTests: XCTestCase {
    func testUpdateDownloadsValidatesAndPersistsList() async throws {
        let (viewModel, store, _) = try makeViewModel(
            fetch: { _, _ in .modified(Data("1.0.1.0/24\n1.0.2.0/23\n".utf8), etag: nil) }
        )

        await viewModel.update()

        XCTAssertEqual(viewModel.rangeCount, 2)
        XCTAssertEqual(viewModel.message, "国内 IP 库已更新，下次连接生效。")
        XCTAssertEqual(try store.load(), "1.0.1.0/24\n1.0.2.0/23\n")
        XCTAssertNotNil(viewModel.updatedAt)
    }

    func testUpdateRejectsInvalidContent() async throws {
        let (viewModel, store, _) = try makeViewModel(
            fetch: { _, _ in .modified(Data("not-a-cidr\n".utf8), etag: nil) }
        )

        await viewModel.update()

        XCTAssertEqual(viewModel.rangeCount, 0)
        XCTAssertTrue(viewModel.message?.contains("更新失败") == true)
        XCTAssertNil(try store.load())
    }

    func testUpdateRejectsEmptyList() async throws {
        let (viewModel, store, _) = try makeViewModel(
            fetch: { _, _ in .modified(Data("\n".utf8), etag: nil) }
        )

        await viewModel.update()

        XCTAssertTrue(viewModel.message?.contains("更新失败") == true)
        XCTAssertNil(try store.load())
    }

    func testUpdateSkipsSaveWhenServerReportsNotModified() async throws {
        let recorder = FetchRecorder()
        let (viewModel, store, _) = try makeViewModel(fetch: recorder.fetch)
        recorder.result = .modified(Data("1.0.1.0/24\n".utf8), etag: "v1")
        await viewModel.update()

        recorder.result = .notModified
        await viewModel.update()

        XCTAssertEqual(recorder.etags, [nil, "v1"])
        XCTAssertEqual(viewModel.message, "国内 IP 库已是最新，无需更新。")
        XCTAssertEqual(viewModel.rangeCount, 1)
        XCTAssertEqual(try store.load(), "1.0.1.0/24\n")
    }

    func testUpdateSkipsSaveWhenContentUnchanged() async throws {
        let (viewModel, _, _) = try makeViewModel(
            fetch: { _, _ in .modified(Data("1.0.1.0/24\n".utf8), etag: nil) }
        )

        await viewModel.update()
        await viewModel.update()

        XCTAssertEqual(viewModel.message, "国内 IP 库已是最新，无需更新。")
        XCTAssertEqual(viewModel.rangeCount, 1)
    }

    func testUpdateDropsETagWhenSourceURLChanges() async throws {
        let recorder = FetchRecorder()
        let (viewModel, _, _) = try makeViewModel(fetch: recorder.fetch)
        recorder.result = .modified(Data("1.0.1.0/24\n".utf8), etag: "v1")
        await viewModel.update()

        viewModel.sourceURL = "https://example.com/other.txt"
        await viewModel.update()

        XCTAssertEqual(recorder.etags, [nil, nil])
    }

    func testLoadReadsPreviouslySavedList() throws {
        let (viewModel, store, _) = try makeViewModel(
            fetch: { _, _ in .modified(Data("1.0.1.0/24\n".utf8), etag: nil) }
        )
        try store.save("1.0.1.0/24\n1.0.2.0/23\n1.0.8.0/21\n")

        let reloaded = IPListViewModel(
            store: store,
            fetch: { _, _ in .notModified },
            defaults: try makeIsolatedDefaults()
        )

        XCTAssertEqual(viewModel.rangeCount, 0)
        XCTAssertEqual(reloaded.rangeCount, 3)
    }

    private func makeViewModel(
        fetch: @escaping CNIPListFetching
    ) throws -> (IPListViewModel, CNIPListStore, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = CNIPListStore(
            fileURL: directory.appendingPathComponent("cn-ip-list.txt")
        )
        let defaults = try makeIsolatedDefaults()
        let viewModel = IPListViewModel(store: store, fetch: fetch, defaults: defaults)
        return (viewModel, store, defaults)
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "IPListViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.coderInvalidValue)
        }
        return defaults
    }
}

private final class FetchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedETags: [String?] = []
    var result: CNIPListFetchResult = .notModified

    var etags: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return recordedETags
    }

    func fetch(_ url: String, etag: String?) async throws -> CNIPListFetchResult {
        lock.lock()
        recordedETags.append(etag)
        let value = result
        lock.unlock()
        return value
    }
}
