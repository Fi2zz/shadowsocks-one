import SwiftUI
import WebKit

/// 只负责把 TabManager 缓存中的 WebView 挂到容器上，绝不创建。
/// tabID 变化时 SwiftUI 调 updateUIView，在此换挂接对象；容器视图本身复用，
/// WebView 不因视图重建 / fullScreenCover 弹出而销毁，页面状态得以保留。
struct BrowserWebViewContainer: UIViewRepresentable {
    let tabID: UUID
    /// 底部 chrome 区高度（工具栏展开 = 工具栏区 + 底部安全区；收起 = 0，
    /// 内容延伸到物理底部，对应 Safari 底栏收起态）
    let bottomInset: CGFloat

    func makeUIView(context: Context) -> UIView {
        let container = BrowserContainerView()
        container.backgroundColor = .systemBackground
        container.bottomInset = bottomInset
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let container = container as? BrowserContainerView else {
            return
        }
        let webView = BrowserTabManager.shared.webView(for: tabID)
        if webView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            container.addSubview(webView)
            container.setNeedsLayout()
        }
        if container.bottomInset != bottomInset {
            container.bottomInset = bottomInset
            if container.window != nil {
                UIView.animate(withDuration: 0.2) { container.layoutIfNeeded() }
            }
        }
    }
}

/// Safari 式原生层安全区：WebView 的 frame 从顶部安全区下方开始、
/// 底部 chrome 区上方结束，两端安全区域归原生 chrome 所有（染色层绘制）。
/// 网页布局视口因此天然不含安全区（env(safe-area-inset-*) 恒为 0，
/// 与 Safari 浏览器展开态一致），也不依赖 contentInset 补丁。
final class BrowserContainerView: UIView {
    var bottomInset: CGFloat = 0 {
        didSet {
            guard oldValue != bottomInset else { return }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let webView = subviews.first else {
            return
        }
        let topInset = safeAreaInsets.top != 0
            ? safeAreaInsets.top
            : (window?.safeAreaInsets.top ?? 0)
        let height = max(bounds.height - topInset - bottomInset, 0)
        webView.frame = CGRect(x: 0, y: topInset, width: bounds.width, height: height)
    }
}
