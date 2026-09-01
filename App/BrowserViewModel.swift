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

    private var observations: [NSKeyValueObservation] = []
    private var folding = ToolbarFoldingMachine()

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
            return keyboardHeight + BrowserChromeMetrics.expandedChromeContent
        }
        let content = toolbarCollapsed
            ? BrowserChromeMetrics.collapsedChromeContent
            : BrowserChromeMetrics.expandedChromeContent
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
        guard let scrollView = BrowserTabManager.shared.activeWebView?.scrollView
        else { return }
        let collapsedMax = maxOffsetY(of: scrollView, bottomInset: collapsedBottomInset)
        let restingAtBottom = scrollView.contentOffset.y >= collapsedMax - 1
        folding.expand(baseline: scrollView.contentOffset.y)
        toolbarCollapsed = folding.collapsed
        // 页底展开：inset 变大后原停留位会被更高的 chrome 遮住，
        // 同步补偿到新最大偏移（动画与 chrome 展开同期完成）
        guard restingAtBottom else { return }
        let target = maxOffsetY(of: scrollView, bottomInset: expandedBottomInset)
        scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
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

    /// 滚动事件转交纯逻辑状态机（ToolbarFoldingMachine），镜像其折叠态驱动 chrome 动画
    private func handleScroll(in scrollView: UIScrollView) {
        folding.handleScroll(
            offsetY: scrollView.contentOffset.y,
            collapsedMaxOffsetY: maxOffsetY(of: scrollView, bottomInset: collapsedBottomInset)
        )
        toolbarCollapsed = folding.collapsed
    }

    private var collapsedBottomInset: CGFloat {
        bottomSafeArea + BrowserChromeMetrics.collapsedChromeContent
    }

    private var expandedBottomInset: CGFloat {
        bottomSafeArea + BrowserChromeMetrics.expandedChromeContent
    }

    /// 给定底部 inset 下的最大合法偏移：超出部分会被系统钳制
    private func maxOffsetY(of scrollView: UIScrollView, bottomInset: CGFloat) -> CGFloat {
        scrollView.contentSize.height - scrollView.bounds.height + bottomInset
    }
}
