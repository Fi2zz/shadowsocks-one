import XCTest
@testable import SharedCore

final class BrowserPageTintTests: XCTestCase {
    func testParsesProbeMessage() {
        let tint = BrowserPageTint(message: "51,119,255,1")
        XCTAssertEqual(tint?.red, 51)
        XCTAssertEqual(tint?.green, 119)
        XCTAssertEqual(tint?.blue, 255)
        XCTAssertEqual(tint?.alpha, 1)
    }

    func testNoneAndMalformedMessagesYieldNil() {
        XCTAssertNil(BrowserPageTint(message: nil))
        XCTAssertNil(BrowserPageTint(message: BrowserTintProbeMessage.none))
        XCTAssertNil(BrowserPageTint(message: "51,119,255"))
        XCTAssertNil(BrowserPageTint(message: "a,b,c,d"))
    }

    func testResolvesTranslucencyOverBackground() {
        let glass = BrowserPageTint(red: 255, green: 255, blue: 255, alpha: 0.5)
        let resolved = glass.resolved(over: BrowserPageTint(red: 0, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(resolved.red, 127.5, accuracy: 0.001)
        XCTAssertEqual(resolved.alpha, 1)
    }

    func testOpaqueTintIgnoresBackground() {
        let opaque = BrowserPageTint(red: 51, green: 119, blue: 255, alpha: 1)
        let resolved = opaque.resolved(over: BrowserPageTint(red: 0, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(resolved, opaque)
    }

    func testQQBluePrefersLightStatusBarText() {
        let qqBlue = BrowserPageTint(message: "51,119,255,1")
        XCTAssertEqual(qqBlue?.prefersLightStatusBarText, true)
    }

    func testWhiteKeepsDarkStatusBarText() {
        let white = BrowserPageTint(red: 255, green: 255, blue: 255, alpha: 1)
        XCTAssertEqual(white.prefersLightStatusBarText, false)
    }

    func testNearThresholdGraySplits() {
        let mid = BrowserPageTint(red: 188, green: 188, blue: 188, alpha: 1)
        XCTAssertEqual(mid.prefersLightStatusBarText, false)
        let dark = BrowserPageTint(red: 64, green: 64, blue: 64, alpha: 1)
        XCTAssertEqual(dark.prefersLightStatusBarText, true)
    }
}
