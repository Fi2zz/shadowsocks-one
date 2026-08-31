import Foundation
import SharedCore
import WebKit

/// 主界面状态：地址栏文本、加载进度、前进后退可用性、工具栏折叠、
/// 后台打开 Toast。对当前激活 WebView 的 KVO 观察在切标签时整体替换
/// （旧 observation 随数组释放自动失效）。
@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var addressText = ""
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var toolbarCollapsed = false
    @Published var loadError: String?
    @Published var showSwitcher = false
    @Published var backgroundToastTabID: UUID?
    @Published var pageTint: BrowserPageTint?
    /// 页面 meta theme-color（KVO 监听），优先于 JS 采样结果
    @Published var themeColorTint: BrowserPageTint?

    /// 底部安全区高度由视图层注入（GeometryReader 读取），供 chrome 高度与钳制补偿计算
    var bottomSafeArea: CGFloat = 0

    /// 展开态 chrome 内容高：工具栏 68 + 间距 4
    private static let expandedChromeContent: CGFloat = 72
    /// 收起态 chrome 内容高：胶囊 36 + 上下间距 20
    private static let collapsedChromeContent: CGFloat = 56

    private var observations: [NSKeyValueObservation] = []
    private var lastScrollOffsetY: CGFloat = 0

    init() {
        wireDelegateCallbacks()
        observeActiveWebView()
    }

    var activePageURL: URL? {
        BrowserTabManager.shared.selectedTab?.url
    }

    /// 底部 chrome 总高：展开 = 工具栏 + 安全区；收起 = 胶囊 + 安全区
    /// （Safari 收起态内容仍停在胶囊上方，不沉到其背后）；键盘在时改为键盘 + 工具栏高度
    func bottomChromeHeight(keyboardHeight: CGFloat) -> CGFloat {
        if keyboardHeight > 0 {
            return keyboardHeight + Self.expandedChromeContent
        }
        let content = toolbarCollapsed ? Self.collapsedChromeContent : Self.expandedChromeContent
        return bottomSafeArea + content
    }

    /// 激活标签变化时调用：重建 KVO 观察，并把各状态同步到新 WebView 当前值
    func observeActiveWebView() {
        guard let webView = BrowserTabManager.shared.activeWebView else {
            return
        }
        addressText = webView.url?.host ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        progress = webView.estimatedProgress
        pageTint = nil
        themeColorTint = themeColorTint(of: webView)
        observations = makeObservations(for: webView)
        reprobeTint(webView)
    }

    /// 已有 meta theme-color 时直接采用（KVO 前的初值），否则等待探针采样
    private func themeColorTint(of webView: WKWebView) -> BrowserPageTint? {
        guard let color = webView.themeColor else { return nil }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return BrowserPageTint(red: red, green: green, blue: blue, alpha: alpha)
    }

    // MARK: - 用户操作

    func loadAddress() {
        guard let url = BrowserURLBuilder.makeURL(from: addressText) else {
            return
        }
        BrowserTabManager.shared.open(url)
    }

    func goBack() {
        BrowserTabManager.shared.activeWebView?.goBack()
    }

    func goForward() {
        BrowserTabManager.shared.activeWebView?.goForward()
    }

    func reload() {
        BrowserTabManager.shared.activeWebView?.reload()
    }

    func expandToolbar() {
        toolbarCollapsed = false
        // 基准点对齐当前偏移，否则展开后首个滚动事件会算出巨量 delta 立刻又折叠
        lastScrollOffsetY = BrowserTabManager.shared.activeWebView?.scrollView.contentOffset.y ?? 0
    }

    func viewBackgroundTab() {
        guard let id = backgroundToastTabID else {
            return
        }
        backgroundToastTabID = nil
        BrowserTabManager.shared.selectTab(id)
        observeActiveWebView()
    }

    func createTab() {
        BrowserTabManager.shared.createTab()
        observeActiveWebView()
    }

    // MARK: - 内部

    private func wireDelegateCallbacks() {
        let delegate = BrowserWebViewDelegate.shared
        delegate.onLoadStarted = { [weak self] in self?.loadError = nil }
        delegate.onLoadFailed = { [weak self] message in self?.loadError = message }
        delegate.onBackgroundOpen = { [weak self] id in self?.backgroundToastTabID = id }
        delegate.onTint = { [weak self] webView, top, _ in
            self?.applyTint(top, from: webView)
        }
    }

    /// 探针消息只接受激活标签的 WebView，后台标签加载不抢占 chrome 颜色；
    /// 底部颜色不再使用（底部 chrome 已改为内容透底，不再染色）
    private func applyTint(_ top: String?, from webView: WKWebView) {
        guard BrowserTabManager.shared.tabID(for: webView) == BrowserTabManager.shared.activeTabID
        else { return }
        pageTint = BrowserPageTint(message: top)
    }

    /// 切标签后主动重发当前颜色（JS 侧有去重，需 force 绕过）
    private func reprobeTint(_ webView: WKWebView) {
        Task { @MainActor in
            _ = try? await webView.evaluateJavaScript(BrowserTintProbe.reprobeScript)
        }
    }

    private func makeObservations(for webView: WKWebView) -> [NSKeyValueObservation] {
        [
            webView.observe(\.url, options: .new) { [weak self] observed, _ in
                Task { @MainActor in self?.addressText = observed.url?.host ?? "" }
            },
            webView.observe(\.estimatedProgress, options: .new) { [weak self] observed, _ in
                Task { @MainActor in self?.progress = observed.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: .new) { [weak self] observed, _ in
                Task { @MainActor in self?.canGoBack = observed.canGoBack }
            },
            webView.observe(\.canGoForward, options: .new) { [weak self] observed, _ in
                Task { @MainActor in self?.canGoForward = observed.canGoForward }
            },
            webView.observe(\.themeColor, options: .new) { [weak self] observed, _ in
                Task { @MainActor in self?.themeColorTint = self?.themeColorTint(of: observed) }
            },
            webView.scrollView.observe(\.contentOffset, options: .new) { [weak self] scrollView, _ in
                Task { @MainActor in self?.handleScroll(in: scrollView) }
            },
        ]
    }

    /// 下滚超过阈值折叠工具栏，上滚超过阈值恢复；未翻转时基准点跟随当前方向极值，
    /// 保证任意位置反向滚动 24pt 即可翻转（Safari 手感），同时形成迟滞避免抖动
    private func handleScroll(in scrollView: UIScrollView) {
        let offsetY = scrollView.contentOffset.y
        let delta = offsetY - lastScrollOffsetY
        let scrollingDown = delta > 24 && offsetY > 0
        let scrollingUp = delta < -24
        if scrollingDown, !toolbarCollapsed {
            collapseToolbar(offsetY: offsetY)
            return
        }
        if scrollingUp, toolbarCollapsed {
            expandToolbar(offsetY: offsetY)
            return
        }
        followBaseline(offsetY: offsetY, scrollView: scrollView)
    }

    /// 折叠态基准点跟随下移极值、展开态跟随上移极值；橡皮筋越界部分不跟进，
    /// 松手回弹不会被误判为反向滚动
    private func followBaseline(offsetY: CGFloat, scrollView: UIScrollView) {
        if toolbarCollapsed {
            let maxY = scrollView.contentSize.height - scrollView.bounds.height + collapsedBottomInset
            lastScrollOffsetY = max(lastScrollOffsetY, min(offsetY, maxY))
            return
        }
        lastScrollOffsetY = min(lastScrollOffsetY, max(offsetY, 0))
    }

    /// 折叠后底部 inset 降为收起态高度，超出新最大偏移的部分会被系统钳掉；这段钳制
    /// 位移不是用户滚动，基准点必须同步下移，否则会被误判为上滚而反复展开/折叠（底部颤抖）
    private func collapseToolbar(offsetY: CGFloat) {
        toolbarCollapsed = true
        lastScrollOffsetY = offsetY - clampedDrop(offsetY: offsetY)
    }

    private func expandToolbar(offsetY: CGFloat) {
        toolbarCollapsed = false
        lastScrollOffsetY = offsetY
    }

    private var collapsedBottomInset: CGFloat {
        bottomSafeArea + Self.collapsedChromeContent
    }

    /// 折叠后 offsetY 超出新最大偏移的量（即将被钳制的距离）
    private func clampedDrop(offsetY: CGFloat) -> CGFloat {
        guard let scrollView = BrowserTabManager.shared.activeWebView?.scrollView else {
            return 0
        }
        let newMaxY = scrollView.contentSize.height - scrollView.bounds.height + collapsedBottomInset
        return max(0, offsetY - newMaxY)
    }
}
