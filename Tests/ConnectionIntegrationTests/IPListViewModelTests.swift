import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksOne

@MainActor
final class IPListViewModelTests: XCTestCase {
    func testUpdateDownloadsValidatesAndPersistsList() async throws {
        let (viewModel, store, _) = try makeViewModel(
            fetch: { _ in Data("1.0.1.0/24\n1.0.2.0/23\n".utf8) }
        )

        await viewModel.update()

        XCTAssertEqual(viewModel.rangeCount, 2)
        XCTAssertEqual(viewModel.message, "国内 IP 库已更新，下次连接生效。")
        XCTAssertEqual(try store.load(), "1.0.1.0/24\n1.0.2.0/23\n")
        XCTAssertNotNil(viewModel.updatedAt)
    }

    func testUpdateRejectsInvalidContent() async throws {
        let (viewModel, store, _) = try makeViewModel(
            fetch: { _ in Data("not-a-cidr\n".utf8) }
        )

        await viewModel.update()

        XCTAssertEqual(viewModel.rangeCount, 0)
        XCTAssertTrue(viewModel.message?.contains("更新失败") == true)
        XCTAssertNil(try store.load())
    }

    func testUpdateRejectsEmptyList() async throws {
        let (viewModel, store, _) = try makeViewModel(
            fetch: { _ in Data("\n".utf8) }
        )

        await viewModel.update()

        XCTAssertTrue(viewModel.message?.contains("更新失败") == true)
        XCTAssertNil(try store.load())
    }

    func testLoadReadsPreviouslySavedList() throws {
        let (viewModel, store, _) = try makeViewModel(
            fetch: { _ in Data("1.0.1.0/24\n".utf8) }
        )
        try store.save("1.0.1.0/24\n1.0.2.0/23\n1.0.8.0/21\n")

        let reloaded = IPListViewModel(
            store: store,
            fetch: { _ in Data() },
            defaults: try makeIsolatedDefaults()
        )

        XCTAssertEqual(viewModel.rangeCount, 0)
        XCTAssertEqual(reloaded.rangeCount, 3)
    }

    private func makeViewModel(
        fetch: @escaping (String) async throws -> Data
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
