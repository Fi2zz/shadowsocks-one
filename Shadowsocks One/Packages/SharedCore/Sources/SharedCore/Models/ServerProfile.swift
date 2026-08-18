import Foundation

public struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let host: String
    public let port: UInt16
    public let method: CipherMethod
    public let password: String
    public let remark: String?
    public let plugin: String?
    public let pluginOptions: String?

    public init(
        id: UUID = UUID(),
        host: String,
        port: UInt16,
        method: CipherMethod,
        password: String,
        remark: String? = nil,
        plugin: String? = nil,
        pluginOptions: String? = nil
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.method = method
        self.password = password
        self.remark = remark
        self.plugin = plugin
        self.pluginOptions = pluginOptions
    }

    public var displayName: String {
        let trimmedRemark = remark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedRemark.isEmpty ? host : trimmedRemark
    }

    public var subtitle: String {
        "\(method.rawValue) • \(host):\(port)"
    }
}
