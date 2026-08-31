import CoreGraphics

/// 底部 chrome 高度预算的唯一来源：工具栏/胶囊布局改动必须同步本文件，
/// 否则 WebView 避让 inset 与实际 chrome 高度漂移（见 design.md §7）。
enum BrowserChromeMetrics {
    /// 地址胶囊内容高（BrowserToolbar.addressField 的 frame height）
    static let fieldContentHeight: CGFloat = 24
    /// 地址胶囊/图标按钮的垂直内边距
    static let capsuleVerticalPadding: CGFloat = 14
    /// 工具栏整行的垂直外边距
    static let barVerticalPadding: CGFloat = 8
    /// 进度条与工具栏的间距
    static let barSpacing: CGFloat = 4
    /// 折叠胶囊的底部间距
    static let pillBottomPadding: CGFloat = 10

    /// 展开态 chrome 内容高：胶囊 52 + 工具栏边距 16 + 间距 4 = 72
    static var expandedChromeContent: CGFloat {
        fieldContentHeight + capsuleVerticalPadding * 2 + barVerticalPadding * 2 + barSpacing
    }

    /// 收起态 chrome 内容高预算：大于胶囊实际高度（约 20 + 底部间距），
    /// 保证收起态滚动内容不沉到胶囊背后
    static let collapsedChromeContent: CGFloat = 56
}
