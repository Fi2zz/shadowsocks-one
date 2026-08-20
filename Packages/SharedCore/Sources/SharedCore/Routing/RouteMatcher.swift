import Foundation

public enum RouteDecision: String, Equatable, Sendable {
    case direct
    case proxy
}

public final class RouteMatcher {
    // 本地/内网网段无条件直连，不进入代理
    private static let privateRangeStrings = [
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "224.0.0.0/4",
    ]

    private let configuration: RoutingConfiguration
    private let cnIPRanges: CNIPRangeList
    private let privateRanges: CNIPRangeList
    private let domainRules: [DomainMatchRule]
    private let proxyRules: [DomainMatchRule]

    public init(
        configuration: RoutingConfiguration,
        cnIPRanges: CNIPRangeList
    ) {
        self.configuration = configuration
        self.cnIPRanges = cnIPRanges
        // 静态常量，格式合法，`try!` 不会触发
        self.privateRanges = try! CNIPRangeList(ranges: Self.privateRangeStrings)
        self.domainRules = configuration.domainWhitelist.map(DomainMatchRule.init(rawValue:))
        self.proxyRules = configuration.proxyDomains.map(DomainMatchRule.init(rawValue:))
    }

    public func route(forHost host: String?, ipString: String) -> RouteDecision {
        if let host, proxyRules.contains(where: { $0.matches(host) }) {
            return .proxy
        }

        if matchesDirectRule(host: host, ipString: ipString) {
            return .direct
        }

        return configuration.directByDefault ? .direct : .proxy
    }

    /// DNS 解析路径决策：只看域名规则与默认路由，不看 IP 规则
    ///（解析发生时尚无目的 IP；CN 段判断保留给 TCP 建连时做）。
    public func dnsDecision(forHost host: String) -> RouteDecision {
        if proxyRules.contains(where: { $0.matches(host) }) {
            return .proxy
        }
        if domainRules.contains(where: { $0.matches(host) }) {
            return .direct
        }
        return configuration.directByDefault ? .direct : .proxy
    }

    private func matchesDirectRule(host: String?, ipString: String) -> Bool {
        if privateRanges.contains(ipString) {
            return true
        }
        if let host, domainRules.contains(where: { $0.matches(host) }) {
            return true
        }
        return configuration.bypassCNIP && cnIPRanges.contains(ipString)
    }
}
