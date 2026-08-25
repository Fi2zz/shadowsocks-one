import WebKit

/// 所有 WebView 共用的导航/UI 代理：接住新窗口链接（后台开标签）、
/// 外部 scheme 交给系统、WebContent 进程被杀自动恢复。
/// 页面事件通过闭包转发给 BrowserViewModel（错误横幅、后台打开 Toast）。
@MainActor
final class BrowserWebViewDelegate: NSObject {
    static let shared = BrowserWebViewDelegate()

    var onBackgroundOpen: ((UUID) -> Void)?
    var onLoadStarted: (() -> Void)?
    var onLoadFailed: ((String) -> Void)?

    private static let supportedSchemes = ["http", "https", "about"]
}

extension BrowserWebViewDelegate: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              !Self.supportedSchemes.contains(scheme)
        else {
            return decisionHandler(.allow)
        }
        // tel: / mailto: / itms-apps: / 第三方 App
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onLoadStarted?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        BrowserTabManager.shared.handleDidFinish(webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    // WebContent 进程被系统杀掉（内存压力）：不处理就是白屏
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // 重定向/新导航取代旧导航时系统报 -999 (cancelled)，属正常噪音
    private func report(_ error: Error) {
        let nsError = error as NSError
        let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        guard !cancelled else {
            return
        }
        onLoadFailed?("\(error.localizedDescription) (\(nsError.domain) \(nsError.code))")
    }
}

extension BrowserWebViewDelegate: WKUIDelegate {
    // 新窗口链接 → 后台新建标签，不打断当前浏览（不接则 target="_blank" 点击无反应）
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url
        else { return nil }
        let tab = BrowserTabManager.shared.createTab(url: url, activate: false)
        onBackgroundOpen?(tab.id)
        return nil
    }
}
