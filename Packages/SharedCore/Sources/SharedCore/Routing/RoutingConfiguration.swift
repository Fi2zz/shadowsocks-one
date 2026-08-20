import Foundation

public struct RoutingConfiguration: Codable, Equatable, Sendable {
    public let bypassCNIP: Bool
    public let domainWhitelist: [String]

    public init(
        bypassCNIP: Bool,
        domainWhitelist: [String]
    ) {
        self.bypassCNIP = bypassCNIP
        self.domainWhitelist = domainWhitelist
    }

    public static let `default` = RoutingConfiguration(
        bypassCNIP: false,
        domainWhitelist: []
    )
}
