import CoreGraphics

/// 底部 chrome 高度预算的唯一来源：工具栏/胶囊布局改动必须同步本文件，
/// 否则 WebView 避让 inset 与实际 chrome 高度漂移（见 design.md §7）。
enum BrowserChromeMetrics {
    /// 地址胶囊内容高（BrowserToolbar.addressField 的 frame height）
    static let fieldContentHeight: CGFloat = 24
    /// 地址胶囊/图标按钮的垂直内边距：10——胶囊 44pt（对齐 Safari 展开栏实测）
    static let capsuleVerticalPadding: CGFloat = 10
    /// 工具栏整行的垂直外边距（顶部）
    static let barVerticalPadding: CGFloat = 8
    /// 工具栏整行的底部外边距：0——胶囊底边贴安全区（对齐 Safari 的 ~34.7pt）
    static let barBottomPadding: CGFloat = 0
    /// 折叠胶囊的底部间距（对齐 Safari 收缩胶囊实测 ~14.7pt）
    static let pillBottomPadding: CGFloat = 15
    /// 折叠/展开整体缩放比：折叠胶囊高（≈31）/ 展开栏高（52），
    /// 整条工具栏作为整体缩放（对齐 Safari 形变手感）
    static let toolbarCollapseScale: CGFloat = 31 / 52

    /// 展开态 chrome 内容高：胶囊 44 + 顶部边距 8 = 52（进度条已并入地址胶囊内底边）
    static var expandedChromeContent: CGFloat {
        fieldContentHeight + capsuleVerticalPadding * 2 + barVerticalPadding + barBottomPadding
    }

    /// 收起态 chrome 内容高预算：胶囊实际高度（30）+ 底部间距（15）+ 防沉底边距（8）
    /// − 底部安全区（34）= 19；保证收起态滚动内容停在胶囊上方
    static let collapsedChromeContent: CGFloat = 19
}
