import XCTest
@testable import SharedCore

final class TunnelConfigurationStoreTests: XCTestCase {
    func testFailsWhenLaunchConfigurationIsMissing() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store = TunnelConfigurationStore(
            jsonURL: tempDirectory.appendingPathComponent("tunnel.json"),
            keychain: InMemoryPasswordStore()
        )

        XCTAssertThrowsError(try store.loadLaunchConfiguration()) { error in
            XCTAssertEqual(
                error as? TunnelConfigurationError,
                .missingConfiguration
            )
        }
    }

    func testSavesAndLoadsLaunchConfiguration() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let keychain = InMemoryPasswordStore()
        let store = TunnelConfigurationStore(
            jsonURL: tempDirectory.appendingPathComponent("tunnel.json"),
            keychain: keychain
        )
        let profile = ServerProfile(
            host: "example.com",
            port: 8388,
            method: .aes256GCM,
            password: "secret",
            remark: "Tokyo"
        )

        try store.save(profile: profile)
        let configuration = try store.loadConfiguration()
        let launchConfiguration = try store.loadLaunchConfiguration()

        XCTAssertEqual(configuration?.profileID, profile.id)
        XCTAssertEqual(configuration?.host, "example.com")
        XCTAssertEqual(launchConfiguration.profileID, profile.id)
        XCTAssertEqual(launchConfiguration.connection.host, "example.com")
        XCTAssertEqual(launchConfiguration.connection.password, "secret")
    }

    func testRejectsPluginProfilesForLaunchConfiguration() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store = TunnelConfigurationStore(
            jsonURL: tempDirectory.appendingPathComponent("tunnel.json"),
            keychain: InMemoryPasswordStore()
        )
        let profile = ServerProfile(
            host: "example.com",
            port: 8388,
            method: .aes128GCM,
            password: "secret",
            remark: "obfs",
            plugin: "obfs-local"
        )

        try store.save(profile: profile)

        XCTAssertThrowsError(try store.loadLaunchConfiguration()) { error in
            XCTAssertEqual(
                error as? TunnelConfigurationError,
                .unsupportedPlugin("obfs-local")
            )
        }
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

    func deletePassword(account: String) throws {
    }
}
