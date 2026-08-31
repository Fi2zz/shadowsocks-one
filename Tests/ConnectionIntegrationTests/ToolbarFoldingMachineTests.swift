import XCTest
@testable import ShadowsocksBrowser

/// 工具栏折叠状态机单测：阈值翻转、迟滞跟随、钳制补偿、橡皮筋不跟进。
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

    func testClampCompensationPreventsBottomJitter() {
        var machine = ToolbarFoldingMachine()

        // 在 200 处折叠，但折叠态最大偏移只有 150：系统将把偏移钳回 150，
        // 这段钳制位移不得被误判为上滚而重新展开
        machine.handleScroll(offsetY: 200, collapsedMaxOffsetY: 150)
        machine.handleScroll(offsetY: 150, collapsedMaxOffsetY: 150)

        XCTAssertTrue(machine.collapsed)
    }

    func testRubberBandBeyondMaxDoesNotFlip() {
        var machine = ToolbarFoldingMachine()
        machine.handleScroll(offsetY: 100, collapsedMaxOffsetY: 150)

        // 底部橡皮筋越界（180 > max 150）不跟进，松手回到 150 不翻转
        machine.handleScroll(offsetY: 180, collapsedMaxOffsetY: 150)
        machine.handleScroll(offsetY: 150, collapsedMaxOffsetY: 150)

        XCTAssertTrue(machine.collapsed)
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
