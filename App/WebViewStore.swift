import WebKit

@MainActor
final class WebViewStore: ObservableObject, Identifiable {
    let id = UUID()
    let webView = BrowserWebView()

    @Published private(set) var title = "新标签页"
    @Published private(set) var currentURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loadError: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var toolbarCollapsed = false

    var onFinishNavigation: ((URL, String) -> Void)?

    private var progressObservation: NSKeyValueObservation?
    private var offsetObservation: NSKeyValueObservation?
    private var lastOffsetY: CGFloat = 0

    init() {
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.progress = webView.estimatedProgress
            }
        }
        offsetObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            Task { @MainActor in
                self?.handleScroll(offsetY: scrollView.contentOffset.y)
            }
        }
    }

    func expandToolbar() {
        toolbarCollapsed = false
        lastOffsetY = 0
    }

    /// 下滚超过阈值折叠工具栏，上滚超过阈值恢复；基准点只在状态翻转时更新，形成迟滞避免抖动
    private func handleScroll(offsetY: CGFloat) {
        let delta = offsetY - lastOffsetY
        if delta > 24, offsetY > 0 {
            toolbarCollapsed = true
            lastOffsetY = offsetY
        } else if delta < -24 {
            toolbarCollapsed = false
            lastOffsetY = offsetY
        }
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    func syncState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
        if let pageTitle = webView.title, !pageTitle.isEmpty {
            title = pageTitle
        }
    }

    func clearLoadError() {
        loadError = nil
    }

    func reportFailure(_ error: Error) {
        let nsError = error as NSError
        // 重定向/新导航取代旧导航时系统报 -999 (cancelled)，属正常噪音
        let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        guard !cancelled else {
            return
        }
        loadError = "\(error.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    func reportFinishedNavigation() {
        guard let url = webView.url else {
            return
        }
        onFinishNavigation?(url, webView.title ?? url.host ?? url.absoluteString)
    }
}
