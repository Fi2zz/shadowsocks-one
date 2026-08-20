import XCTest
@testable import SharedCore

final class CNIPListStoreTests: XCTestCase {
    func testSavesAndLoadsContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CNIPListStore(
            fileURL: directory.appendingPathComponent("cn-ip-list.txt")
        )

        try store.save("1.0.1.0/24\n1.0.2.0/23\n")

        XCTAssertEqual(try store.load(), "1.0.1.0/24\n1.0.2.0/23\n")
    }

    func testReturnsNilWhenFileIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let store = CNIPListStore(
            fileURL: directory.appendingPathComponent("cn-ip-list.txt")
        )

        XCTAssertNil(try store.load())
    }
}
