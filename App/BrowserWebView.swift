import WebKit

/// SwiftUI 的 ignoresSafeArea 会把传给 WKWebView 的安全区清零，
/// 网页文档会从屏幕 y=0 开始渲染并与状态栏文字重叠。
/// 这里把窗口安全区高度手动设为滚动内容 inset，让文档起点下沉到状态栏下方。
/// 注意 WKWebView 会在布局时重置手动 contentInset，所以放在 layoutSubviews 里重设。
final class BrowserWebView: WKWebView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let topInset = window?.safeAreaInsets.top else {
            return
        }
        guard scrollView.contentInset.top != topInset else {
            return
        }
        scrollView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 80, right: 0)
        scrollView.verticalScrollIndicatorInsets = scrollView.contentInset
    }
}

/// WebView 唯一的创建入口：由 BrowserTabManager 在需要时调用，
/// 实例归 TabManager 的缓存所有，SwiftUI 视图只负责挂载、绝不创建。
@MainActor
enum BrowserWebViewFactory {
    static func make() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        BrowserTintProbe.install(into: configuration, handler: BrowserWebViewDelegate.shared)
        let webView = BrowserWebView(frame: .zero, configuration: configuration)
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
