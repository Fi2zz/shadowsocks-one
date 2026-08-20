import Foundation

public struct TunnelLaunchConfiguration: Sendable, Equatable {
    public let profileID: UUID
    public let connection: ConnectionConfig
    public let plugin: String?
    public let pluginOptions: String?

    public init(
        profileID: UUID,
        connection: ConnectionConfig,
        plugin: String?,
        pluginOptions: String?
    ) {
        self.profileID = profileID
        self.connection = connection
        self.plugin = plugin
        self.pluginOptions = pluginOptions
    }
}
