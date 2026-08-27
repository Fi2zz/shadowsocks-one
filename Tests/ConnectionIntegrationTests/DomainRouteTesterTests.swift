import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksBrowser

final class DomainRouteTesterTests: XCTestCase {
    func testUnlistedDomainReportsProxyWithoutConnect() async {
        let tester = DomainRouteTester(resolver: StubResolver(addresses: ["8.8.8.8"]))

        let result = await tester.test(
            entry: "google.com",
            configuration: RoutingConfiguration(bypassCNIP: false, domainWhitelist: []),
            cnIPRanges: .empty
        )

        XCTAssertEqual(result.decision, .proxy)
        XCTAssertEqual(result.addresses, ["8.8.8.8"])
        XCTAssertNil(result.connectMilliseconds)
        XCTAssertNil(result.failureDescription)
        XCTAssertEqual(result.summaryText, "走代理")
    }

    func testWildcardEntryUsesRepresentativeSubdomainForDecision() async {
        let tester = DomainRouteTester(resolver: StubResolver(addresses: []))

        let result = await tester.test(
            entry: "*.qq.com",
            configuration: RoutingConfiguration(
                bypassCNIP: false,
                domainWhitelist: ["*.qq.com"]
            ),
            cnIPRanges: .empty
        )

        XCTAssertEqual(result.decision, .direct)
        XCTAssertEqual(result.failureDescription, "解析失败")
    }

    func testCNAddressWithBypassEnabledReportsDirect() async {
        // 1ns 超时让直连实测立即失败，避免测试访问真实网络
        let tester = DomainRouteTester(
            resolver: StubResolver(addresses: ["1.2.4.8"]),
            timeoutNanoseconds: 1
        )

        let result = await tester.test(
            entry: "cnnic.cn",
            configuration: RoutingConfiguration(bypassCNIP: true, domainWhitelist: []),
            cnIPRanges: try! CNIPRangeList(ranges: ["1.2.4.0/24"])
        )

        XCTAssertEqual(result.decision, .direct)
        XCTAssertEqual(result.failureDescription, "连接失败")
    }

    private struct StubResolver: DNSResolving {
        let addresses: [String]

        func resolve(host: String) async throws -> [String] {
            addresses
        }
    }
}
