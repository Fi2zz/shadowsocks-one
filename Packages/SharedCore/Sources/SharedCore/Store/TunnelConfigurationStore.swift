import Foundation

public final class TunnelConfigurationStore {
    private let jsonURL: URL
    private let keychain: any PasswordStoring
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(appGroupID: String, keychainService: String) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        self.jsonURL = containerURL.appendingPathComponent("tunnel-configuration.json")
        self.keychain = PasswordKeychain(service: keychainService)
    }

    init(jsonURL: URL, keychain: any PasswordStoring) {
        self.jsonURL = jsonURL
        self.keychain = keychain
    }

    public func save(profile: ServerProfile) throws {
        let configuration = TunnelConfiguration(profile: profile)
        let data = try encoder.encode(configuration)
        try data.write(to: jsonURL, options: .atomic)
        try keychain.savePassword(profile.password, account: profile.id.uuidString)
    }

    public func loadConfiguration() throws -> TunnelConfiguration? {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: jsonURL)
        return try decoder.decode(TunnelConfiguration.self, from: data)
    }

    public func loadLaunchConfiguration() throws -> TunnelLaunchConfiguration {
        guard let configuration = try loadConfiguration() else {
            throw TunnelConfigurationError.missingConfiguration
        }

        if let plugin = configuration.plugin {
            throw TunnelConfigurationError.unsupportedPlugin(plugin)
        }

        guard let password = try keychain.loadPassword(account: configuration.profileID.uuidString),
              !password.isEmpty else {
            throw TunnelConfigurationError.missingPassword
        }

        return TunnelLaunchConfiguration(
            profileID: configuration.profileID,
            connection: ConnectionConfig(
                host: configuration.host,
                port: configuration.port,
                method: configuration.method,
                password: password
            ),
            plugin: configuration.plugin,
            pluginOptions: configuration.pluginOptions
        )
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: jsonURL)
    }
}
