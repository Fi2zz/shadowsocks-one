import XCTest
@testable import SharedCore

final class RoutingConfigurationStoreTests: XCTestCase {
    func testSavesAndLoadsRoutingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RoutingConfigurationStore(
            jsonURL: directory.appendingPathComponent("routing.json")
        )
        let configuration = RoutingConfiguration(
            bypassCNIP: true,
            domainWhitelist: ["*.qq.com", "taobao.com"]
        )

        try store.save(configuration)

        XCTAssertEqual(try store.load(), configuration)
    }

    func testReturnsDefaultConfigurationWhenFileIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RoutingConfigurationStore(
            jsonURL: directory.appendingPathComponent("routing.json")
        )

        XCTAssertEqual(try store.load(), .default)
    }
}
