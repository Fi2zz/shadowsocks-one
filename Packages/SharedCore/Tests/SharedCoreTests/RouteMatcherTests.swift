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
}
