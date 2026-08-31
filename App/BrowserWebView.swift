import WebKit

/// WebView 唯一的创建入口：由 BrowserTabManager 在需要时调用，
/// 实例归 TabManager 的缓存所有，SwiftUI 视图只负责挂载、绝不创建。
/// frame 全屏（Safari 路线）：顶部状态栏区域完全交给页面，底部 chrome 避让
/// 由 BrowserChromeViewController 双通道下发（公开安全区 + WebKit 显式 inset），
/// 与 Safari 的 chrome/内容分离同构。
@MainActor
enum BrowserWebViewFactory {
    static func make() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        BrowserTintProbe.install(into: configuration, handler: BrowserWebViewDelegate.shared)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // 保持默认 .automatic：WebKit 经安全区管线自动处理 env 上报、fixed
        // 元素布局视口、滚动范围与指示条（安全区由 BrowserChromeViewController 注入）
        webView.customUserAgent = safariUserAgent()
        webView.allowsBackForwardNavigationGestures = true
        let delegate = BrowserWebViewDelegate.shared
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        return webView
    }

    /// WKWebView 默认 UA 缺 Version/Safari 令牌，会被站点识别为内嵌 WebView
    /// （QQ 新闻据此插入「打开 App」横幅甚至跳旧版页）。构造与系统 Safari 完全一致的 UA。
    /// REASON: iOS 26 起 Safari 的 OS 令牌冻结为 18_7（同 macOS 的 10_15_7 冻结策略），
    /// 与 Mobile/15E148 一样是长期冻结值，故硬编码；Version/ 仍跟随系统大版本。
    private static func safariUserAgent() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osToken = version.majorVersion >= 26
            ? "18_7"
            : "\(version.majorVersion)_\(version.minorVersion)"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osToken) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(version.majorVersion).\(version.minorVersion) Mobile/15E148 Safari/604.1"
    }
}
