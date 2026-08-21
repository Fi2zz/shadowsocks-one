import SwiftUI
import WebKit

/// SwiftUI 的 ignoresSafeArea 会把传给 WKWebView 的安全区清零，
/// 网页文档会从屏幕 y=0 开始渲染并与状态栏文字重叠。
/// 这里把窗口安全区高度手动设为滚动内容 inset，让文档起点下沉到状态栏下方。
/// 注意 WKWebView 会在布局时重置手动 contentInset，所以放在 layoutSubviews 里重设。
final class BrowserWebView: WKWebView {
    override func layoutSubviews() {
        super.layoutSubviews()
        let topInset = window?.safeAreaInsets.top ?? 0
        guard scrollView.contentInset.top != topInset else {
            return
        }
        scrollView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 80, right: 0)
        scrollView.verticalScrollIndicatorInsets = scrollView.contentInset
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let store: WebViewStore

    func makeUIView(context: Context) -> WKWebView {
        store.webView.navigationDelegate = context.coordinator
        return store.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let store: WebViewStore

        init(store: WebViewStore) {
            self.store = store
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            store.clearLoadError()
            store.syncState()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            store.syncState()
            store.reportFinishedNavigation()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            store.syncState()
            store.reportFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            store.syncState()
            store.reportFailure(error)
        }
    }
}
