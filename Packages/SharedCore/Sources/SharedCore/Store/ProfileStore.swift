import Foundation

private struct ProfileRecord: Codable {
    let id: UUID
    let host: String
    let port: UInt16
    let method: CipherMethod
    let remark: String?
    let plugin: String?
    let pluginOptions: String?
}

public final class ProfileStore {
    private let jsonURL: URL
    private let defaults: UserDefaults
    private let keychain: any PasswordStoring

    public init(appGroupID: String, keychainService: String) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard let suiteDefaults = UserDefaults(suiteName: appGroupID) else {
            throw CocoaError(.coderInvalidValue)
        }

        self.jsonURL = containerURL.appendingPathComponent("profiles.json")
        self.defaults = suiteDefaults
        self.keychain = PasswordKeychain(service: keychainService)
    }

    public init(
        localDirectory: URL,
        keychainService: String,
        defaults: UserDefaults = .standard
    ) throws {
        try FileManager.default.createDirectory(
            at: localDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        self.jsonURL = localDirectory.appendingPathComponent("profiles.json")
        self.defaults = defaults
        self.keychain = PasswordKeychain(service: keychainService)
    }

    init(
        jsonURL: URL,
        defaults: UserDefaults,
        keychain: any PasswordStoring
    ) {
        self.jsonURL = jsonURL
        self.defaults = defaults
        self.keychain = keychain
    }

    public func saveProfiles(_ profiles: [ServerProfile]) throws {
        let records = profiles.map {
            ProfileRecord(
                id: $0.id,
                host: $0.host,
                port: $0.port,
                method: $0.method,
                remark: $0.remark,
                plugin: $0.plugin,
                pluginOptions: $0.pluginOptions
            )
        }

        let data = try JSONEncoder().encode(records)
        try data.write(to: jsonURL, options: .atomic)

        for profile in profiles {
            try keychain.savePassword(profile.password, account: profile.id.uuidString)
        }
    }

    public func loadProfiles() throws -> [ServerProfile] {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            return []
        }

        let data = try Data(contentsOf: jsonURL)
        let records = try JSONDecoder().decode([ProfileRecord].self, from: data)
        return try records.map { record in
            let password = try keychain.loadPassword(account: record.id.uuidString) ?? ""
            return ServerProfile(
                id: record.id,
                host: record.host,
                port: record.port,
                method: record.method,
                password: password,
                remark: record.remark,
                plugin: record.plugin,
                pluginOptions: record.pluginOptions
            )
        }
    }

    public func loadSelectedProfileID() -> UUID? {
        defaults.string(forKey: "selectedProfileID").flatMap(UUID.init(uuidString:))
    }

    public func saveSelectedProfileID(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: "selectedProfileID")
    }

    public func deleteProfile(id: UUID, from profiles: [ServerProfile]) throws {
        try saveProfiles(profiles.filter { $0.id != id })
        try keychain.deletePassword(account: id.uuidString)
    }
}
