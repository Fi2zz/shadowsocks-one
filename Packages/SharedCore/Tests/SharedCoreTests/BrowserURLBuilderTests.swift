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
}
