import XCTest
@testable import SharedCore

final class RouteMatcherTests: XCTestCase {
    func testMatchesCNIPAddressAsDirect() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: true,
                domainWhitelist: []
            ),
            cnIPRanges: try CNIPRangeList(ranges: ["1.0.1.0/24"])
        )

        XCTAssertEqual(
            matcher.route(forHost: nil, ipString: "1.0.1.8"),
            .direct
        )
    }

    func testMatchesWildcardWhitelistedDomainAsDirect() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: false,
                domainWhitelist: ["*.qq.com"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: [])
        )

        XCTAssertEqual(
            matcher.route(forHost: "www.qq.com", ipString: "203.0.113.10"),
            .direct
        )
    }

    func testMatchesExactWhitelistedDomainCaseInsensitively() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: false,
                domainWhitelist: ["TaObAo.Com"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: [])
        )

        XCTAssertEqual(
            matcher.route(forHost: "taobao.com.", ipString: "203.0.113.10"),
            .direct
        )
    }

    func testWildcardDoesNotMatchApexDomain() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: false,
                domainWhitelist: ["*.qq.com"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: [])
        )

        XCTAssertEqual(
            matcher.route(forHost: "qq.com", ipString: "203.0.113.10"),
            .proxy
        )
    }

    func testFallsBackToProxyWhenNoRuleMatches() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: true,
                domainWhitelist: ["*.qq.com"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: ["1.0.1.0/24"])
        )

        XCTAssertEqual(
            matcher.route(forHost: "www.google.com", ipString: "142.250.72.196"),
            .proxy
        )
    }

    func testMatchesProxyDomainAsProxy() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: false,
                domainWhitelist: [],
                proxyDomains: ["*.google.com"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: [])
        )

        XCTAssertEqual(
            matcher.route(forHost: "www.google.com", ipString: "142.250.72.196"),
            .proxy
        )
    }

    func testFallsBackToProxyForUnlistedDomain() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: false,
                domainWhitelist: [],
                proxyDomains: ["*.google.com"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: [])
        )

        XCTAssertEqual(
            matcher.route(forHost: "www.qq.com", ipString: "203.0.113.10"),
            .proxy
        )
    }

    func testProxyRuleTakesPrecedenceOverWhitelist() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: false,
                domainWhitelist: ["*.qq.com"],
                proxyDomains: ["www.qq.com"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: [])
        )

        XCTAssertEqual(
            matcher.route(forHost: "www.qq.com", ipString: "203.0.113.10"),
            .proxy
        )
    }

    func testMatchesPrivateIPAddressAsDirect() throws {
        let matcher = RouteMatcher(
            configuration: .default,
            cnIPRanges: try CNIPRangeList(ranges: [])
        )

        XCTAssertEqual(matcher.route(forHost: nil, ipString: "192.168.1.1"), .direct)
        XCTAssertEqual(matcher.route(forHost: nil, ipString: "10.0.0.5"), .direct)
        XCTAssertEqual(matcher.route(forHost: nil, ipString: "127.0.0.1"), .direct)
        XCTAssertEqual(matcher.route(forHost: nil, ipString: "8.8.8.8"), .proxy)
    }

    func testProxyRuleTakesPrecedenceOverPrivateIPDirect() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: false,
                domainWhitelist: [],
                proxyDomains: ["nas.lan"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: [])
        )

        XCTAssertEqual(
            matcher.route(forHost: "nas.lan", ipString: "192.168.1.10"),
            .proxy
        )
    }

    func testDNSDecisionUsesDomainRulesOnly() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: true,
                domainWhitelist: ["qq.com"],
                proxyDomains: ["*.google.com"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: ["1.0.1.0/24"])
        )

        XCTAssertEqual(matcher.dnsDecision(forHost: "www.google.com"), .proxy)
        XCTAssertEqual(matcher.dnsDecision(forHost: "qq.com"), .direct)
        // 未命中名单的域名必须远程解析防污染；bypassCNIP 不影响 DNS 决策（解析时还没有 IP）
        XCTAssertEqual(matcher.dnsDecision(forHost: "www.baidu.com"), .proxy)
    }
}
