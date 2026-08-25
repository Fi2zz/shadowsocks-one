import WebKit

/// WebView 唯一的创建入口：由 BrowserTabManager 在需要时调用，
/// 实例归 TabManager 的缓存所有，SwiftUI 视图只负责挂载、绝不创建。
/// 顶部/底部安全区与工具栏避让都在 frame 层处理（BrowserContainerView），
/// 与 Safari 的 chrome/内容分离同构。
@MainActor
enum BrowserWebViewFactory {
    static func make() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        BrowserTintProbe.install(into: configuration, handler: BrowserWebViewDelegate.shared)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = safariUserAgent()
        webView.allowsBackForwardNavigationGestures = true
        let delegate = BrowserWebViewDelegate.shared
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        return webView
    }

    /// WKWebView 默认 UA 缺 Version/Safari 令牌，会被站点识别为内嵌 WebView
    /// （QQ 新闻据此插入「打开 App」横幅甚至跳旧版页）。构造与系统 Safari 一致的 UA，
    /// Safari 大版本与 iOS 保持一致；WebKit 版本号 605.1.15 是固定值。
    private static func safariUserAgent() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "CPU iPhone OS \(version.majorVersion)_\(version.minorVersion) like Mac OS X"
        return "Mozilla/5.0 (\(os)) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(version.majorVersion).\(version.minorVersion) Mobile/15E148 Safari/604.1"
    }
}
