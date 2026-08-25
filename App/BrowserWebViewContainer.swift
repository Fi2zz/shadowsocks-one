import SwiftUI
import WebKit

/// 只负责把 TabManager 缓存中的 WebView 挂到容器上，绝不创建。
/// tabID 变化时 SwiftUI 调 updateUIView，在此换挂接对象；容器视图本身复用，
/// WebView 不因视图重建 / fullScreenCover 弹出而销毁，页面状态得以保留。
struct BrowserWebViewContainer: UIViewRepresentable {
    let tabID: UUID

    func makeUIView(context: Context) -> UIView {
        let container = BrowserContainerView()
        container.backgroundColor = .systemBackground
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let webView = BrowserTabManager.shared.webView(for: tabID)
        guard webView.superview !== container else {
            return
        }
        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(webView)
    }
}

/// Safari 式原生层安全区：WebView 的 frame 从顶部安全区下方开始，
/// 状态栏区域归原生 chrome（BrowserRootView 的染色层）所有。
/// 网页布局视口因此天然不含安全区（env(safe-area-inset-*) 恒为 0，
/// 与 Safari 浏览器行为一致），也不依赖 contentInset 补丁。
final class BrowserContainerView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let webView = subviews.first else {
            return
        }
        let topInset = safeAreaInsets.top != 0
            ? safeAreaInsets.top
            : (window?.safeAreaInsets.top ?? 0)
        webView.frame = CGRect(
            x: 0,
            y: topInset,
            width: bounds.width,
            height: max(bounds.height - topInset, 0)
        )
    }
}
