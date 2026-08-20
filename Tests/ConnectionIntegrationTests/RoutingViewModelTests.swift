import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksOne

@MainActor
final class WhitelistViewModelTests: XCTestCase {
    func testAddEntryAppendsNormalizedDomainAndPersists() throws {
        let (viewModel, store) = try makeViewModel()

        viewModel.newEntry = " WWW.QQ.COM. "
        viewModel.addEntry()

        XCTAssertEqual(viewModel.domains, ["www.qq.com"])
        XCTAssertEqual(viewModel.newEntry, "")
        XCTAssertEqual(try store.load().domainWhitelist, ["www.qq.com"])
    }

    func testAddEntryRejectsEmptyAndDuplicateEntries() throws {
        let (viewModel, _) = try makeViewModel()

        viewModel.newEntry = "   "
        viewModel.addEntry()
        viewModel.newEntry = "qq.com"
        viewModel.addEntry()
        viewModel.newEntry = "qq.com"
        viewModel.addEntry()

        XCTAssertEqual(viewModel.domains, ["qq.com"])
    }

    func testDeleteEntriesRemovesDomainAndPersists() throws {
        let (viewModel, store) = try makeViewModel()

        viewModel.newEntry = "qq.com"
        viewModel.addEntry()
        viewModel.newEntry = "*.baidu.com"
        viewModel.addEntry()
        viewModel.deleteEntries(at: IndexSet(integer: 0))

        XCTAssertEqual(viewModel.domains, ["*.baidu.com"])
        XCTAssertEqual(try store.load().domainWhitelist, ["*.baidu.com"])
    }

    func testPersistPreservesBypassCNIPFromLoadedConfiguration() throws {
        let (_, store) = try makeViewModel()
        try store.save(RoutingConfiguration(bypassCNIP: true, domainWhitelist: []))
        let viewModel = WhitelistViewModel(store: store)

        viewModel.newEntry = "qq.com"
        viewModel.addEntry()

        let persisted = try store.load()
        XCTAssertTrue(persisted.bypassCNIP)
        XCTAssertEqual(persisted.domainWhitelist, ["qq.com"])
    }

    private func makeViewModel() throws -> (WhitelistViewModel, RoutingConfigurationStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = RoutingConfigurationStore(
            jsonURL: directory.appendingPathComponent("routing-configuration.json")
        )
        return (WhitelistViewModel(store: store), store)
    }
}
