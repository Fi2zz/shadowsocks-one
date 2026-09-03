import CoreGraphics
import SwiftUI

/// 底部 chrome 高度预算的唯一来源：工具栏/胶囊布局改动必须同步本文件，
/// 否则 WebView 避让 inset 与实际 chrome 高度漂移（见 design.md §7）。
enum BrowserChromeMetrics {
    /// 地址胶囊内容高（BrowserToolbar.addressField 的 frame height）
    static let fieldContentHeight: CGFloat = 24
    /// 地址胶囊/图标按钮的垂直内边距：10——胶囊 44pt（对齐 Safari 展开栏实测）
    static let capsuleVerticalPadding: CGFloat = 10
    /// 工具栏整行的垂直外边距（顶部）
    static let barVerticalPadding: CGFloat = 8
    /// 工具栏整行的水平边距：收窄地址胶囊（前后按钮组宽度不受影响）
    static let barHorizontalPadding: CGFloat = 18
    /// 工具栏整行的底部外边距：0——胶囊底边贴安全区（对齐 Safari 的 ~34.7pt）
    static let barBottomPadding: CGFloat = 0
    /// 折叠胶囊的底部间距（对齐 Safari 收缩胶囊实测 ~14.7pt）
    static let pillBottomPadding: CGFloat = 15
    /// 折叠/展开整体缩放比：折叠胶囊高（≈31）/ 展开栏高（52），
    /// 整条工具栏作为整体缩放（对齐 Safari 形变手感）
    static let toolbarCollapseScale: CGFloat = 31 / 52
    /// 折叠/展开的 spring（点胶囊展开、页底自动展开等离散事件）；
    /// 滚动跟手形变不经过动画，由 progress 直接驱动
    static let collapseSpring = Animation.spring(response: 0.4, dampingFraction: 0.85)
    /// 滚动跟手的平滑时间常数（限速器）：慢拖逐帧跟随，快划时形变
    /// 完成不快于该时长，避免一瞬而过
    static let morphFollow = Animation.easeOut(duration: 0.25)
    /// 大条与胶囊可见度交叉点（交替窗口中点），命中测试切换用
    static let morphHitCrossover: CGFloat = 0.675

    /// 形变时间轴（对齐 Safari：大条与迷你胶囊叠放、中段窄窗口交替——
    /// 大条先缩过大半行程再淡出，胶囊只在交替窗口淡入并长到位）
    private static func clampedRamp(_ progress: CGFloat, start: CGFloat, end: CGFloat) -> CGFloat {
        min(1, max(0, (progress - start) / (end - start)))
    }

    /// 展开栏缩放：全程前 80% 行程 1 → toolbarCollapseScale，bottom 锚点
    static func expandedBarScale(progress: CGFloat) -> CGFloat {
        1 - clampedRamp(progress, start: 0, end: 0.8) * (1 - toolbarCollapseScale)
    }

    /// 展开栏可见度：前半程全显，0.5 → 0.85 淡出
    static func expandedBarOpacity(progress: CGFloat) -> CGFloat {
        1 - clampedRamp(progress, start: 0.5, end: 0.85)
    }

    /// 迷你胶囊可见度：0.5 → 0.85 淡入，与展开栏交替
    static func collapsedPillOpacity(progress: CGFloat) -> CGFloat {
        clampedRamp(progress, start: 0.5, end: 0.85)
    }

    /// 迷你胶囊缩放：0.45 → 1 行程内 toolbarCollapseScale → 1 长到位
    static func collapsedPillScale(progress: CGFloat) -> CGFloat {
        toolbarCollapseScale
            + clampedRamp(progress, start: 0.45, end: 1) * (1 - toolbarCollapseScale)
    }

    /// 展开态 chrome 内容高：胶囊 44 + 顶部边距 8 = 52（进度条已并入地址胶囊内底边）
    static var expandedChromeContent: CGFloat {
        fieldContentHeight + capsuleVerticalPadding * 2 + barVerticalPadding + barBottomPadding
    }

    /// 收起态 chrome 内容高预算：胶囊实际高度（30）+ 底部间距（15）+ 防沉底边距（8）
    /// − 底部安全区（34）= 19；保证收起态滚动内容停在胶囊上方
    static let collapsedChromeContent: CGFloat = 19
    /// 收缩态迷你胶囊的最小内容宽度：host 很短时保证整条胶囊仍是可点热区
    static let collapsedPillMinWidth: CGFloat = 88
    /// Toast 与底部 chrome 顶边的间距
    static let toastBottomGap: CGFloat = 16
}
