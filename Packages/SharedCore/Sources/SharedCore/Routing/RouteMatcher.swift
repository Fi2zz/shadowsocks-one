import Foundation

public enum RouteDecision: String, Equatable, Sendable {
    case direct
    case proxy
}

public final class RouteMatcher {
    private let configuration: RoutingConfiguration
    private let cnIPRanges: CNIPRangeList
    private let domainRules: [DomainMatchRule]

    public init(
        configuration: RoutingConfiguration,
        cnIPRanges: CNIPRangeList
    ) {
        self.configuration = configuration
        self.cnIPRanges = cnIPRanges
        self.domainRules = configuration.domainWhitelist.map(DomainMatchRule.init(rawValue:))
    }

    public func route(forHost host: String?, ipString: String) -> RouteDecision {
        if let host, domainRules.contains(where: { $0.matches(host) }) {
            return .direct
        }

        if configuration.bypassCNIP, cnIPRanges.contains(ipString) {
            return .direct
        }

        return .proxy
    }
}
