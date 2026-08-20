import XCTest
@testable import SharedCore

final class DNSCacheTests: XCTestCase {
    func testExpiresCachedAddressAfterTTL() {
        var now = Date(timeIntervalSince1970: 0)
        let cache = DNSCache(now: { now })

        cache.insert(domain: "www.qq.com", addresses: ["203.0.113.10"], ttl: 10)

        XCTAssertTrue(cache.contains(domain: "www.qq.com", address: "203.0.113.10"))

        now = Date(timeIntervalSince1970: 11)

        XCTAssertFalse(cache.contains(domain: "www.qq.com", address: "203.0.113.10"))
    }

    func testMatchesDomainCaseInsensitivelyAndIgnoresTrailingDot() {
        let cache = DNSCache(now: { Date(timeIntervalSince1970: 0) })

        cache.insert(domain: "TaObAo.Com.", addresses: ["203.0.113.20"], ttl: 60)

        XCTAssertTrue(cache.contains(domain: "taobao.com", address: "203.0.113.20"))
        XCTAssertTrue(cache.contains(domain: "TAOBAO.COM.", address: "203.0.113.20"))
    }

    func testDoesNotMatchUnknownAddress() {
        let cache = DNSCache(now: { Date(timeIntervalSince1970: 0) })

        cache.insert(
            domain: "www.qq.com",
            addresses: ["203.0.113.10", "203.0.113.11"],
            ttl: 60
        )

        XCTAssertFalse(cache.contains(domain: "www.qq.com", address: "203.0.113.12"))
    }
}
