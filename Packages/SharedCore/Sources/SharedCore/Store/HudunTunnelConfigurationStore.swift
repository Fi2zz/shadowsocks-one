import Foundation

/// 护盾 WireGuard 启动配置持久化（app group）：
/// JSON 存公开字段，本端私钥入 Keychain；另存活动模式标记。
public final class HudunTunnelConfigurationStore {
    private let containerURL: URL
    private let jsonURL: URL
    private let modeURL: URL
    private let keychain: any PasswordStoring

    public static let privateKeyAccount = "hudun-wg-privatekey"

    public init(appGroupID: String, keychainService: String) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.containerURL = containerURL
        self.jsonURL = containerURL.appendingPathComponent("hudun-wg-configuration.json")
        self.modeURL = containerURL.appendingPathComponent("active-tunnel-mode.json")
        self.keychain = PasswordKeychain(service: keychainService)
    }

    init(containerURL: URL, keychain: any PasswordStoring) {
        self.containerURL = containerURL
        self.jsonURL = containerURL.appendingPathComponent("hudun-wg-configuration.json")
        self.modeURL = containerURL.appendingPathComponent("active-tunnel-mode.json")
        self.keychain = keychain
    }

    /// 保存配置并切换活动模式为 wireguard。
    public func activate(_ configuration: HudunTunnelLaunchConfiguration,
                         privateKeyBase64: String) throws {
        try keychain.savePassword(privateKeyBase64, account: Self.privateKeyAccount)
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: jsonURL, options: .atomic)
        try setMode(.wireguard)
    }

    public func loadLaunchConfiguration()
        throws -> (configuration: HudunTunnelLaunchConfiguration, privateKeyBase64: String) {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw TunnelConfigurationError.missingConfiguration
        }
        guard let privateKey = try keychain.loadPassword(account: Self.privateKeyAccount),
              !privateKey.isEmpty else {
            throw TunnelConfigurationError.missingPassword
        }
        let data = try Data(contentsOf: jsonURL)
        let configuration = try JSONDecoder()
            .decode(HudunTunnelLaunchConfiguration.self, from: data)
        return (configuration, privateKey)
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: jsonURL)
    }

    public func setMode(_ mode: ActiveTunnelMode) throws {
        let data = try JSONEncoder().encode(mode)
        try data.write(to: modeURL, options: .atomic)
    }

    public func loadMode() -> ActiveTunnelMode? {
        guard let data = try? Data(contentsOf: modeURL),
              let mode = try? JSONDecoder().decode(ActiveTunnelMode.self, from: data) else {
            return nil
        }
        return mode
    }
}
