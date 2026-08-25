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

    private var observations: [NSKeyValueObservation] = []
    private var lastScrollOffsetY: CGFloat = 0

    init() {
        wireDelegateCallbacks()
        observeActiveWebView()
    }

    var activePageURL: URL? {
        BrowserTabManager.shared.selectedTab?.url
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
        observations = makeObservations(for: webView)
        reprobeTint(webView)
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
        lastScrollOffsetY = 0
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
        delegate.onTint = { [weak self] webView, payload in self?.applyTint(payload, from: webView) }
    }

    /// 探针消息只接受激活标签的 WebView，后台标签加载不抢占状态栏颜色
    private func applyTint(_ payload: String?, from webView: WKWebView) {
        guard BrowserTabManager.shared.tabID(for: webView) == BrowserTabManager.shared.activeTabID
        else { return }
        pageTint = BrowserPageTint(message: payload)
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
            webView.scrollView.observe(\.contentOffset, options: .new) { [weak self] scrollView, _ in
                Task { @MainActor in self?.handleScroll(offsetY: scrollView.contentOffset.y) }
            },
        ]
    }

    /// 下滚超过阈值折叠工具栏，上滚超过阈值恢复；基准点只在状态翻转时更新，形成迟滞避免抖动
    private func handleScroll(offsetY: CGFloat) {
        let delta = offsetY - lastScrollOffsetY
        if delta > 24, offsetY > 0 {
            toolbarCollapsed = true
            lastScrollOffsetY = offsetY
        } else if delta < -24 {
            toolbarCollapsed = false
            lastScrollOffsetY = offsetY
        }
    }
}
