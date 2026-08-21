import Foundation
import XCTest
@testable import ShadowsocksOne

final class ConnectionTesterTests: XCTestCase {
    func testNormalizeURLAddsHTTPSWhenSchemeMissing() {
        XCTAssertEqual(
            ConnectionTester.normalizeURL(from: " www.baidu.com ")?.absoluteString,
            "https://www.baidu.com"
        )
    }

    func testNormalizeURLRejectsEmptyInput() {
        XCTAssertNil(ConnectionTester.normalizeURL(from: "   "))
    }

    func testReportsStatusCodeAndLatencyOnSuccess() async {
        let tester = ConnectionTester { url in
            HTTPURLResponse(
                url: url,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
        }

        let result = await tester.test(urlString: "https://www.google.com/generate_204")

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.statusCode, 204)
        XCTAssertNotNil(result.milliseconds)
        XCTAssertNil(result.failureDescription)
    }

    func testReportsFailureDescriptionOnError() async {
        let tester = ConnectionTester { _ in
            throw URLError(.timedOut)
        }

        let result = await tester.test(urlString: "https://www.google.com")

        XCTAssertFalse(result.succeeded)
        XCTAssertNotNil(result.failureDescription)
    }

    func testRejectsInvalidURL() async {
        let tester = ConnectionTester { _ in
            XCTFail("无效地址不应发起请求")
            throw URLError(.badURL)
        }

        let result = await tester.test(urlString: "   ")

        XCTAssertEqual(result.failureDescription, "地址无效")
    }
}
