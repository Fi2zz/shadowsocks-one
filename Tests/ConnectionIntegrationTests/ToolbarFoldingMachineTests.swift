import XCTest
@testable import ShadowsocksBrowser

/// 工具栏折叠状态机单测：阈值翻转、迟滞跟随、钳制补偿、页底自动展开。
final class ToolbarFoldingMachineTests: XCTestCase {

    func testScrollDownBeyondThresholdCollapses() {
        var machine = ToolbarFoldingMachine()

        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000)

        XCTAssertTrue(machine.collapsed)
    }

    func testScrollBelowThresholdKeepsExpanded() {
        var machine = ToolbarFoldingMachine()

        machine.handleScroll(offsetY: 20, collapsedMaxOffsetY: 5000)

        XCTAssertFalse(machine.collapsed)
    }

    func testCollapsedScrollUpBeyondThresholdExpands() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000)

        machine.handleScroll(offsetY: 60, collapsedMaxOffsetY: 5000)

        XCTAssertFalse(machine.collapsed)
    }

    func testDeepScrollThenSmallReverseFlips() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000)
        machine.handleScroll(offsetY: 300, collapsedMaxOffsetY: 5000)

        // 基准点跟随下移到 300，反向 24pt 以上即恢复展开
        machine.handleScroll(offsetY: 270, collapsedMaxOffsetY: 5000)

        XCTAssertFalse(machine.collapsed)
    }

    func testClampToCollapsedMaxAutoExpandsAtBottom() {
        var machine = ToolbarFoldingMachine()

        // 在 200 处折叠，折叠态最大偏移只有 150：系统钳回 150 即页底停留位，
        // 按页底规格自动展开为完整工具条
        machine.handleScroll(offsetY: 200, collapsedMaxOffsetY: 150)
        machine.handleScroll(offsetY: 150, collapsedMaxOffsetY: 150)

        XCTAssertFalse(machine.collapsed)
    }

    func testRubberBandSettleAtBottomAutoExpands() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 150)

        // 底部橡皮筋越界（180 > max 150）不在中途展开，停稳回到 150 才展开
        machine.handleScroll(offsetY: 180, collapsedMaxOffsetY: 150)
        XCTAssertTrue(machine.collapsed)
        machine.handleScroll(offsetY: 150, collapsedMaxOffsetY: 150)

        XCTAssertFalse(machine.collapsed)
    }

    func testReachCollapsedMaxAutoExpands() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000)

        machine.handleScroll(offsetY: 5000, collapsedMaxOffsetY: 5000)

        XCTAssertFalse(machine.collapsed)
    }

    func testStopShortOfBottomStaysCollapsed() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000)

        // 距页底 10pt（超出容差 2pt）未到达，保持折叠
        machine.handleScroll(offsetY: 4990, collapsedMaxOffsetY: 5000)

        XCTAssertTrue(machine.collapsed)
    }

    func testBottomAutoExpandToleratesCompensationScroll() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 150)
        machine.handleScroll(offsetY: 150, collapsedMaxOffsetY: 150)

        // 自动展开后 inset 变大，ViewModel 补偿下滚 16pt 不得立刻又折叠
        machine.handleScroll(offsetY: 166, collapsedMaxOffsetY: 150)

        XCTAssertFalse(machine.collapsed)
    }

    func testTopRubberBandKeepsExpanded() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: -30, collapsedMaxOffsetY: 5000)
        machine.handleScroll(offsetY: 10, collapsedMaxOffsetY: 5000)

        XCTAssertFalse(machine.collapsed)
    }

    func testTapExpandAlignsBaselineToCurrentOffset() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 5000)
        machine.expand(baseline: 100)

        // 展开后首个滚动事件 delta 从当前偏移起算，小幅滚动不立刻又折叠
        machine.handleScroll(offsetY: 110, collapsedMaxOffsetY: 5000)

        XCTAssertFalse(machine.collapsed)
    }
}
