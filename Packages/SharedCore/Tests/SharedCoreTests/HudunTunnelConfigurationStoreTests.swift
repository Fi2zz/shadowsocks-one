import Foundation
import CryptoKit
import XCTest
@testable import SharedCore

/// Hudun 隧道配置存储：JSON + Keychain 私钥 + 模式标记回环。
final class HudunTunnelConfigurationStoreTests: XCTestCase {

    func testActivateAndLoadRoundTrip() throws {
        let store = makeStore()
        defer { try? store.clear() }
        let privateKey = Data(SymmetricKey(size: SymmetricKeySize.bits256).withUnsafeBytes { Data($0) })
            .base64EncodedString()
        let configuration = HudunTunnelLaunchConfiguration(
            endpointHost: "113.45.52.155", endpointPort: 19921,
            peerPublicKeyBase64: "VPujWFTjDpr9NzCAPvzXuGaEe79vRlsoFBgvQMx15zw=",
            tunnelAddress: "22.105.98.191",
            dnsServers: ["22.0.0.2"], mtu: 1300,
            lineID: 4, lineName: "香港 01")

        try store.activate(configuration, privateKeyBase64: privateKey)
        XCTAssertEqual(store.loadMode(), .wireguard)

        let loaded = try store.loadLaunchConfiguration()
        XCTAssertEqual(loaded.configuration, configuration)
        XCTAssertEqual(loaded.privateKeyBase64, privateKey)
    }

    func testModeDefaultsAndSwitch() throws {
        let store = makeStore()
        XCTAssertNil(store.loadMode())
        try store.setMode(.shadowsocks)
        XCTAssertEqual(store.loadMode(), .shadowsocks)
        try store.setMode(.wireguard)
        XCTAssertEqual(store.loadMode(), .wireguard)
    }

    func testMissingPrivateKeyThrows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hudun-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = HudunTunnelLaunchConfiguration(
            endpointHost: "h", endpointPort: 1,
            peerPublicKeyBase64: "pk", tunnelAddress: "10.0.0.1",
            dnsServers: [], mtu: 1300)
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: directory.appendingPathComponent("hudun-wg-configuration.json"),
                       options: .atomic)

        let store = HudunTunnelConfigurationStore(
            containerURL: directory, keychain: InMemoryKeychain())
        XCTAssertThrowsError(try store.loadLaunchConfiguration())
    }

    // MARK: - 工具

    private func makeStore() -> HudunTunnelConfigurationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hudun-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return HudunTunnelConfigurationStore(
            containerURL: directory, keychain: InMemoryKeychain())
    }
}

private final class InMemoryKeychain: PasswordStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func savePassword(_ password: String, account: String) throws {
        storage[account] = password
    }

    func loadPassword(account: String) throws -> String? {
        storage[account]
    }

    func deletePassword(account: String) throws {
        storage.removeValue(forKey: account)
    }
}
