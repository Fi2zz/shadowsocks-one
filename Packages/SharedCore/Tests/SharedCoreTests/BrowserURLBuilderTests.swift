import XCTest
@testable import SharedCore

final class BrowserURLBuilderTests: XCTestCase {
    func testEmptyInputReturnsNil() {
        XCTAssertNil(BrowserURLBuilder.makeURL(from: ""))
        XCTAssertNil(BrowserURLBuilder.makeURL(from: "   "))
    }

    func testPlainHostGetsHTTPSPrefix() {
        let url = BrowserURLBuilder.makeURL(from: "example.com")
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testPlainHostWithPathGetsHTTPSPrefix() {
        let url = BrowserURLBuilder.makeURL(from: "example.com/path?q=1")
        XCTAssertEqual(url?.absoluteString, "https://example.com/path?q=1")
    }

    func testExistingSchemeIsPreserved() {
        let url = BrowserURLBuilder.makeURL(from: "http://example.com")
        XCTAssertEqual(url?.absoluteString, "http://example.com")
    }

    func testWhitespaceIsTrimmed() {
        let url = BrowserURLBuilder.makeURL(from: "  example.com  \n")
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testInputWithoutHostReturnsNil() {
        XCTAssertNil(BrowserURLBuilder.makeURL(from: "https://"))
    }

    func testQueryWithWhitespaceOpensBingSearch() {
        let url = BrowserURLBuilder.makeURL(from: "swift concurrency guide")
        XCTAssertEqual(
            url?.absoluteString,
            "https://www.bing.com/search?q=swift%20concurrency%20guide"
        )
    }

    func testChineseQueryIsPercentEncoded() {
        let url = BrowserURLBuilder.makeURL(from: "天气预报")
        XCTAssertEqual(url?.host, "www.bing.com")
        XCTAssertEqual(url?.query, "q=%E5%A4%A9%E6%B0%94%E9%A2%84%E6%8A%A5")
    }

    func testSingleWordWithoutDotOpensBingSearch() {
        let url = BrowserURLBuilder.makeURL(from: "wikipedia")
        XCTAssertEqual(url?.absoluteString, "https://www.bing.com/search?q=wikipedia")
    }
}
