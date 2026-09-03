import XCTest
@testable import ShadowsocksBrowser

/// 工具栏折叠状态机单测：阈值翻转、迟滞跟随、页底自动展开、页底稳定区不折叠。
/// collapsedMaxOffsetY 统一取 5000、collapseCeilingOffsetY 取 4200（= 5000 − 800 屏高），
/// 需要短页场景时另行标注。
final class ToolbarFoldingMachineTests: XCTestCase {

    func testScrollDownBeyondThresholdCollapses() {
        var machine = ToolbarFoldingMachine()

        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertTrue(machine.collapsed)
    }

    func testScrollBelowThresholdKeepsExpanded() {
        var machine = ToolbarFoldingMachine()

        machine.handleScroll(offsetY: 20, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertFalse(machine.collapsed)
    }

    func testCollapsedScrollUpBeyondThresholdExpands() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        machine.handleScroll(offsetY: 60, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertFalse(machine.collapsed)
    }

    func testDeepScrollThenSmallReverseFlips() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)
        machine.handleScroll(offsetY: 300, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        // 基准点跟随下移到 300，反向 24pt 以上即恢复展开
        machine.handleScroll(offsetY: 270, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertFalse(machine.collapsed)
    }

    func testShortPageNeverCollapses() {
        var machine = ToolbarFoldingMachine()

        // 短页（max 150 < 屏高 800，稳定区上限为负、覆盖全文）永不折叠
        machine.handleScroll(offsetY: 200, collapsedMaxOffsetY: 150, collapseCeilingOffsetY: -650)

        XCTAssertFalse(machine.collapsed)
    }

    func testRubberBandSettleAtBottomAutoExpands() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        // 底部橡皮筋越界 100pt 不在中途展开，停稳回到 5000 才展开
        machine.handleScroll(offsetY: 5100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)
        XCTAssertTrue(machine.collapsed)
        machine.handleScroll(offsetY: 5000, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertFalse(machine.collapsed)
    }

    func testReachCollapsedMaxAutoExpands() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        machine.handleScroll(offsetY: 5000, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertFalse(machine.collapsed)
    }

    func testStopShortOfBottomStaysCollapsed() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        // 距页底 10pt（超出容差 2pt）未到达，保持折叠
        machine.handleScroll(offsetY: 4990, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertTrue(machine.collapsed)
    }

    func testBottomAutoExpandToleratesCompensationScroll() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)
        machine.handleScroll(offsetY: 5000, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        // 自动展开后 inset 变大，ViewModel 补偿下滚 16pt 不得立刻又折叠
        machine.handleScroll(offsetY: 5016, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertFalse(machine.collapsed)
    }

    func testDragRubberBandAtBottomKeepsExpanded() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)
        machine.handleScroll(offsetY: 5000, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        // 页底展开态下拉橡皮筋 100pt：稳定区内禁止折叠（抖动根因）
        machine.handleScroll(offsetY: 5100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertFalse(machine.collapsed)
    }

    func testWiggleNearBottomKeepsExpanded() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)
        machine.handleScroll(offsetY: 5000, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        // 页底展开态上拖 60pt 再下拖 60pt：下拖终点仍在稳定区内，不折叠
        machine.handleScroll(offsetY: 4940, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)
        machine.handleScroll(offsetY: 5000, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertFalse(machine.collapsed)
    }

    func testCollapseResumesAfterLeavingBottomZone() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)
        machine.handleScroll(offsetY: 5000, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        // 页底展开态上滚两屏再下滚：回到稳定区外，折叠恢复生效
        machine.handleScroll(offsetY: 3600, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)
        machine.handleScroll(offsetY: 3700, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertTrue(machine.collapsed)
    }

    func testTopRubberBandKeepsExpanded() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: -30, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)
        machine.handleScroll(offsetY: 10, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertFalse(machine.collapsed)
    }

    func testTapExpandAlignsBaselineToCurrentOffset() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)
        machine.expand(baseline: 100)

        // 展开后首个滚动事件 delta 从当前偏移起算，小幅滚动不立刻又折叠
        machine.handleScroll(offsetY: 110, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertFalse(machine.collapsed)
    }

    // MARK: - 连续形变进度

    func testPartialDownScrollTracksProgress() {
        var machine = ToolbarFoldingMachine()

        machine.handleScroll(offsetY: 12, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertEqual(machine.progress, 0.5, accuracy: 0.001)
        XCTAssertFalse(machine.collapsed)
    }

    func testCollapseSetsProgressToOne() {
        var machine = ToolbarFoldingMachine()

        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertEqual(machine.progress, 1, accuracy: 0.001)
    }

    func testExpandResetsProgressToZero() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        machine.handleScroll(offsetY: 60, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertEqual(machine.progress, 0, accuracy: 0.001)
    }

    func testPartialProgressReversesWithUpScroll() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 12, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        machine.handleScroll(offsetY: 4, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertEqual(machine.progress, 4.0 / 24.0, accuracy: 0.001)
    }

    func testStableZoneKeepsProgressZero() {
        var machine = ToolbarFoldingMachine()

        // 展开态滚入页底稳定区：进度强制 0，不出现半折叠残态
        machine.handleScroll(offsetY: 4900, collapsedMaxOffsetY: 5000, collapseCeilingOffsetY: 4200)

        XCTAssertEqual(machine.progress, 0, accuracy: 0.001)
        XCTAssertFalse(machine.collapsed)
    }
}
