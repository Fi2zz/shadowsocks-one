import Foundation

public struct TunnelConfiguration: Codable, Equatable, Sendable {
    public let profileID: UUID
    public let host: String
    public let port: UInt16
    public let method: CipherMethod
    public let plugin: String?
    public let pluginOptions: String?

    public init(
        profileID: UUID,
        host: String,
        port: UInt16,
        method: CipherMethod,
        plugin: String? = nil,
        pluginOptions: String? = nil
    ) {
        self.profileID = profileID
        self.host = host
        self.port = port
        self.method = method
        self.plugin = plugin
        self.pluginOptions = pluginOptions
    }

    public init(profile: ServerProfile) {
        self.profileID = profile.id
        self.host = profile.host
        self.port = profile.port
        self.method = profile.method
        self.plugin = profile.plugin
        self.pluginOptions = profile.pluginOptions
    }

    public var requiresPluginSupport: Bool {
        plugin != nil
    }
}
