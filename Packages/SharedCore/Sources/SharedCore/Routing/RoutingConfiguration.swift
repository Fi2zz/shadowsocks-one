import Foundation

public struct RoutingConfiguration: Codable, Equatable, Sendable {
    public let bypassCNIP: Bool
    public let domainWhitelist: [String]
    public let proxyDomains: [String]
    public let directByDefault: Bool

    public init(
        bypassCNIP: Bool,
        domainWhitelist: [String],
        proxyDomains: [String] = [],
        directByDefault: Bool = false
    ) {
        self.bypassCNIP = bypassCNIP
        self.domainWhitelist = domainWhitelist
        self.proxyDomains = proxyDomains
        self.directByDefault = directByDefault
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bypassCNIP = try container.decodeIfPresent(Bool.self, forKey: .bypassCNIP) ?? false
        domainWhitelist = try container.decodeIfPresent([String].self, forKey: .domainWhitelist) ?? []
        proxyDomains = try container.decodeIfPresent([String].self, forKey: .proxyDomains) ?? []
        directByDefault = try container.decodeIfPresent(Bool.self, forKey: .directByDefault) ?? false
    }

    public static let `default` = RoutingConfiguration(
        bypassCNIP: false,
        domainWhitelist: []
    )
}
