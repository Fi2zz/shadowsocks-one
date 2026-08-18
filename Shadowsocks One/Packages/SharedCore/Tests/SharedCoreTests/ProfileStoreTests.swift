import XCTest
@testable import SharedCore

final class ProfileStoreTests: XCTestCase {
    func testProfileRoundTripsWithoutPlaintextPasswordInJSON() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let jsonURL = tempDirectory.appendingPathComponent("profiles.json")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let keychain = InMemoryPasswordStore()
        let store = ProfileStore(jsonURL: jsonURL, defaults: defaults, keychain: keychain)

        let profile = ServerProfile(
            host: "example.com",
            port: 8388,
            method: .aes128GCM,
            password: "secret",
            remark: "demo"
        )

        try store.saveProfiles([profile])
        let jsonString = try String(contentsOf: jsonURL, encoding: .utf8)
        let loaded = try store.loadProfiles()

        XCTAssertFalse(jsonString.contains("secret"))
        XCTAssertEqual(loaded.first?.host, "example.com")
        XCTAssertEqual(loaded.first?.password, "secret")
        XCTAssertEqual(loaded.first?.remark, "demo")
    }

    func testSelectedProfileIDRoundTrips() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ProfileStore(
            jsonURL: tempDirectory.appendingPathComponent("profiles.json"),
            defaults: defaults,
            keychain: InMemoryPasswordStore()
        )
        let id = UUID()

        store.saveSelectedProfileID(id)

        XCTAssertEqual(store.loadSelectedProfileID(), id)
    }
}

private actor InMemoryPasswordStoreBox {
    var storage: [String: String] = [:]

    func save(_ password: String, for account: String) {
        storage[account] = password
    }

    func load(account: String) -> String? {
        storage[account]
    }
}

private struct InMemoryPasswordStore: PasswordStoring {
    private let box = InMemoryPasswordStoreBox()

    func savePassword(_ password: String, account: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await box.save(password, for: account)
            semaphore.signal()
        }
        semaphore.wait()
    }

    func loadPassword(account: String) throws -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var value: String?
        Task {
            value = await box.load(account: account)
            semaphore.signal()
        }
        semaphore.wait()
        return value
    }
}
