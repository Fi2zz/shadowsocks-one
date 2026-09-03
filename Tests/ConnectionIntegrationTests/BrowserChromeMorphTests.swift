import XCTest
@testable import ShadowsocksBrowser

/// 折叠形变时间轴单测（对齐 Safari 叠放交替）：
/// 大条前 80% 行程缩放、中段窄窗口淡出；迷你胶囊同窗口淡入并长到位。
final class BrowserChromeMorphTests: XCTestCase {

    func testExpandedBarShrinksOverFirstEightyPercent() {
        XCTAssertEqual(BrowserChromeMetrics.expandedBarScale(progress: 0), 1, accuracy: 0.001)
        XCTAssertEqual(
            BrowserChromeMetrics.expandedBarScale(progress: 0.8),
            BrowserChromeMetrics.toolbarCollapseScale,
            accuracy: 0.001
        )
    }

    func testLayersAlternateInMidWindow() {
        // 0.5 交替窗口起点：大条全显、胶囊全隐
        XCTAssertEqual(BrowserChromeMetrics.expandedBarOpacity(progress: 0.5), 1, accuracy: 0.001)
        XCTAssertEqual(BrowserChromeMetrics.collapsedPillOpacity(progress: 0.5), 0, accuracy: 0.001)
        // 0.85 交替窗口终点：大条全隐、胶囊全显
        XCTAssertEqual(BrowserChromeMetrics.expandedBarOpacity(progress: 0.85), 0, accuracy: 0.001)
        XCTAssertEqual(BrowserChromeMetrics.collapsedPillOpacity(progress: 0.85), 1, accuracy: 0.001)
    }

    func testPillGrowsWithinItsWindow() {
        XCTAssertEqual(
            BrowserChromeMetrics.collapsedPillScale(progress: 0.45),
            BrowserChromeMetrics.toolbarCollapseScale,
            accuracy: 0.001
        )
        XCTAssertEqual(BrowserChromeMetrics.collapsedPillScale(progress: 1), 1, accuracy: 0.001)
    }
}
