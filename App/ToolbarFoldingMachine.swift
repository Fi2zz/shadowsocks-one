import CoreGraphics

/// 工具栏折叠状态机（纯逻辑，与 UIScrollView 解耦便于单测）：
/// 下滚超过阈值折叠、上滚超过阈值恢复；未翻转时基准点跟随当前方向极值，
/// 保证任意位置反向滚动 24pt 即可翻转（Safari 手感），同时形成迟滞避免抖动。
struct ToolbarFoldingMachine {
    /// 翻转阈值：相对基准点同向滚动超过该值才切换折叠态
    static let flipThreshold: CGFloat = 24

    private(set) var collapsed = false
    private var baseline: CGFloat = 0

    /// collapsedMaxOffsetY：折叠态 inset 下的最大合法偏移
    ///（contentSize.height - bounds.height + 折叠态底部 inset）
    mutating func handleScroll(offsetY: CGFloat, collapsedMaxOffsetY: CGFloat) {
        let delta = offsetY - baseline
        let scrollingDown = delta > Self.flipThreshold && offsetY > 0
        let scrollingUp = delta < -Self.flipThreshold
        if scrollingDown, !collapsed {
            collapse(offsetY: offsetY, collapsedMaxOffsetY: collapsedMaxOffsetY)
            return
        }
        if scrollingUp, collapsed {
            expand(baseline: offsetY)
            return
        }
        followBaseline(offsetY: offsetY, collapsedMaxOffsetY: collapsedMaxOffsetY)
    }

    /// 点击胶囊展开：基准点对齐当前偏移，否则展开后首个滚动事件
    /// 会算出巨量 delta 立刻又折叠
    mutating func expand(baseline offsetY: CGFloat) {
        collapsed = false
        baseline = offsetY
    }

    /// 折叠后底部 inset 降为收起态高度，超出新最大偏移的部分会被系统钳掉；这段钳制
    /// 位移不是用户滚动，基准点必须同步下移，否则会被误判为上滚而反复展开/折叠（底部颤抖）
    private mutating func collapse(offsetY: CGFloat, collapsedMaxOffsetY: CGFloat) {
        collapsed = true
        baseline = offsetY - max(0, offsetY - collapsedMaxOffsetY)
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
}
