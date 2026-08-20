import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksOne

@MainActor
final class RoutingViewModelTests: XCTestCase {
    func testAddEntryAppendsNormalizedDomainAndPersists() throws {
        let (viewModel, store) = try makeViewModel()

        viewModel.directEntry = " WWW.QQ.COM. "
        viewModel.addEntry(for: .direct)

        XCTAssertEqual(viewModel.directDomains, ["www.qq.com"])
        XCTAssertEqual(viewModel.directEntry, "")
        XCTAssertEqual(try store.load().domainWhitelist, ["www.qq.com"])
    }

    func testAddEntryRejectsEmptyAndDuplicateEntries() throws {
        let (viewModel, _) = try makeViewModel()

        viewModel.directEntry = "   "
        viewModel.addEntry(for: .direct)
        viewModel.directEntry = "qq.com"
        viewModel.addEntry(for: .direct)
        viewModel.directEntry = "qq.com"
        viewModel.addEntry(for: .direct)

        XCTAssertEqual(viewModel.directDomains, ["qq.com"])
    }

    func testDeleteEntriesRemovesDomainAndPersists() throws {
        let (viewModel, store) = try makeViewModel()

        viewModel.directEntry = "qq.com"
        viewModel.addEntry(for: .direct)
        viewModel.directEntry = "*.baidu.com"
        viewModel.addEntry(for: .direct)
        viewModel.deleteEntries(at: IndexSet(integer: 0), for: .direct)

        XCTAssertEqual(viewModel.directDomains, ["*.baidu.com"])
        XCTAssertEqual(try store.load().domainWhitelist, ["*.baidu.com"])
    }

    func testProxyListEntriesPersistSeparately() throws {
        let (viewModel, store) = try makeViewModel()

        viewModel.proxyEntry = "*.google.com"
        viewModel.addEntry(for: .proxy)
        viewModel.deleteEntries(at: IndexSet(integer: 0), for: .proxy)
        viewModel.proxyEntry = "google.com"
        viewModel.addEntry(for: .proxy)

        let persisted = try store.load()
        XCTAssertEqual(viewModel.proxyDomains, ["google.com"])
        XCTAssertEqual(persisted.proxyDomains, ["google.com"])
        XCTAssertEqual(persisted.domainWhitelist, [])
    }

    func testSetDirectByDefaultPersistsMode() throws {
        let (viewModel, store) = try makeViewModel()

        viewModel.setDirectByDefault(true)

        XCTAssertTrue(viewModel.directByDefault)
        XCTAssertTrue(try store.load().directByDefault)
    }

    func testSetBypassCNIPPersistsMode() throws {
        let (viewModel, store) = try makeViewModel()

        viewModel.setBypassCNIP(true)

        XCTAssertTrue(viewModel.bypassCNIP)
        XCTAssertTrue(try store.load().bypassCNIP)
    }

    func testPersistPreservesBypassCNIPFromLoadedConfiguration() throws {
        let (_, store) = try makeViewModel()
        try store.save(RoutingConfiguration(bypassCNIP: true, domainWhitelist: []))
        let viewModel = RoutingViewModel(store: store)

        viewModel.directEntry = "qq.com"
        viewModel.addEntry(for: .direct)

        let persisted = try store.load()
        XCTAssertTrue(persisted.bypassCNIP)
        XCTAssertEqual(persisted.domainWhitelist, ["qq.com"])
    }

    func testConnectionStoresResultAndClearsTestingState() async throws {
        let expected = DomainRouteTestResult(
            decision: .direct,
            addresses: ["1.1.1.1"],
            connectMilliseconds: 12,
            failureDescription: nil
        )
        let (viewModel, _) = try makeViewModel { _, _, _ in expected }

        await viewModel.testConnection(for: "qq.com")

        XCTAssertEqual(viewModel.testResults["qq.com"], expected)
        XCTAssertTrue(viewModel.testingDomains.isEmpty)
    }

    func testConnectionPassesCurrentConfiguration() async throws {
        let recorder = ConfigurationRecorder()
        let (viewModel, _) = try makeViewModel { _, configuration, _ in
            recorder.record(configuration)
            return DomainRouteTestResult(
                decision: .proxy,
                addresses: [],
                connectMilliseconds: nil,
                failureDescription: nil
            )
        }
        viewModel.directEntry = "qq.com"
        viewModel.addEntry(for: .direct)
        viewModel.setBypassCNIP(true)

        await viewModel.testConnection(for: "qq.com")

        XCTAssertEqual(recorder.configuration?.domainWhitelist, ["qq.com"])
        XCTAssertTrue(recorder.configuration?.bypassCNIP ?? false)
    }

    private func makeViewModel() throws -> (RoutingViewModel, RoutingConfigurationStore) {
        try makeViewModel(routeTestHandler: nil)
    }

    private func makeViewModel(
        routeTestHandler: RoutingViewModel.RouteTestHandler?
    ) throws -> (RoutingViewModel, RoutingConfigurationStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = RoutingConfigurationStore(
            jsonURL: directory.appendingPathComponent("routing-configuration.json")
        )
        let viewModel = RoutingViewModel(store: store, routeTestHandler: routeTestHandler)
        return (viewModel, store)
    }
}

private final class ConfigurationRecorder {
    private(set) var configuration: RoutingConfiguration?

    func record(_ configuration: RoutingConfiguration) {
        self.configuration = configuration
    }
}
