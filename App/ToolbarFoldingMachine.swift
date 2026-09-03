import CoreGraphics

/// 工具栏折叠状态机（纯逻辑，与 UIScrollView 解耦便于单测）：
/// 下滚超过阈值折叠、上滚超过阈值恢复；未翻转时基准点跟随当前方向极值，
/// 保证任意位置反向滚动 24pt 即可翻转（Safari 手感），同时形成迟滞避免抖动。
/// 折叠态到达页底停留位（含橡皮筋停稳）自动展开，完整工具条随页底出现；
/// 距页底不足一屏为稳定区，区内禁止折叠——页底停留会自动展开，
/// 区内折叠只会立刻被撤销，表现为工具条抖动。
struct ToolbarFoldingMachine {
    /// 翻转阈值：相对基准点同向滚动超过该值才切换折叠态；
    /// 同时是形变行程（progress 0→1 的滚动距离），拉长可让过渡更柔和
    static let flipThreshold: CGFloat = 40
    /// 页底判定容差：停留位恰好等于折叠态最大偏移，橡皮筋越界超出容差不判达，
    /// 停稳回到窗口内才展开（避免回弹中途展开造成 inset 抖动）
    static let bottomTolerance: CGFloat = 2

    private(set) var collapsed = false
    /// 形变进度 0=展开、1=折叠：随滚动连续变化（对齐 Safari 跟手形变）
    private(set) var progress: CGFloat = 0
    private var baseline: CGFloat = 0

    /// collapsedMaxOffsetY：折叠态 inset 下的最大合法偏移
    /// （contentSize.height - bounds.height + 折叠态底部 inset）；
    /// collapseCeilingOffsetY：允许折叠的偏移上限（= 页底停留位 − 一屏高），
    /// 超出即页底稳定区，区内的下滚手势（橡皮筋/小幅来回）不触发折叠
    mutating func handleScroll(
        offsetY: CGFloat,
        collapsedMaxOffsetY: CGFloat,
        collapseCeilingOffsetY: CGFloat
    ) {
        let delta = offsetY - baseline
        let scrollingDown = delta > Self.flipThreshold
            && offsetY > 0 && offsetY <= collapseCeilingOffsetY
        let scrollingUp = delta < -Self.flipThreshold
        if scrollingDown, !collapsed {
            collapse(offsetY: offsetY)
            return
        }
        if scrollingUp, collapsed {
            expand(baseline: offsetY)
            return
        }
        followBaseline(offsetY: offsetY, collapsedMaxOffsetY: collapsedMaxOffsetY)
        expandAtBottomIfNeeded(offsetY: offsetY, collapsedMaxOffsetY: collapsedMaxOffsetY)
        updateProgress(offsetY: offsetY, collapseCeilingOffsetY: collapseCeilingOffsetY)
    }

    /// 点击胶囊展开：基准点对齐当前偏移，否则展开后首个滚动事件
    /// 会算出巨量 delta 立刻又折叠
    mutating func expand(baseline offsetY: CGFloat) {
        collapsed = false
        baseline = offsetY
        progress = 0
    }

    private mutating func collapse(offsetY: CGFloat) {
        collapsed = true
        baseline = offsetY
        progress = 1
    }

    /// 折叠态基准点跟随下移极值、展开态跟随上移极值；橡皮筋越界部分不跟进，
    /// 松手回弹不会被误判为反向滚动
    private mutating func followBaseline(offsetY: CGFloat, collapsedMaxOffsetY: CGFloat) {
        if collapsed {
            baseline = max(baseline, min(offsetY, collapsedMaxOffsetY))
            return
        }
        baseline = min(baseline, max(offsetY, 0))
    }

    /// 折叠态停稳在页底停留位 → 自动展开（页底应露出完整工具条）；
    /// 基准点对齐当前偏移，随后 inset 变大的补偿位移不会立刻又折叠
    private mutating func expandAtBottomIfNeeded(offsetY: CGFloat, collapsedMaxOffsetY: CGFloat) {
        guard collapsed else { return }
        let reachedBottom = abs(offsetY - collapsedMaxOffsetY) <= Self.bottomTolerance
        guard reachedBottom else { return }
        expand(baseline: offsetY)
    }

    /// 进度跟随（对齐 Safari：拖多少变多少）——展开态取自基准点的下滚余量，
    /// 折叠态取 1 减上滚余量；门槛与翻转一致（offsetY > 0 且未入页底稳定区），
    /// 不满足时强制 0，避免虚假事件造成"展开态却全折叠视觉"的脱节
    private mutating func updateProgress(offsetY: CGFloat, collapseCeilingOffsetY: CGFloat) {
        let delta = offsetY - baseline
        if collapsed {
            progress = clampedProgress(1 + delta / Self.flipThreshold)
            return
        }
        guard offsetY > 0, offsetY <= collapseCeilingOffsetY else {
            progress = 0
            return
        }
        progress = clampedProgress(delta / Self.flipThreshold)
    }

    private func clampedProgress(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}
