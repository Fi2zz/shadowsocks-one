import SwiftUI
import WebKit

/// 只负责把 TabManager 缓存中的 WebView 挂到容器上，绝不创建。
/// tabID 变化时 SwiftUI 调 updateUIView，在此换挂接对象；容器视图本身复用，
/// WebView 不因视图重建 / fullScreenCover 弹出而销毁，页面状态得以保留。
struct BrowserWebViewContainer: UIViewRepresentable {
    let tabID: UUID
    /// 底部 chrome 区高度（展开 = 工具栏 + 底部安全区；收起 = 胶囊 + 底部安全区）。
    /// 经 scrollView.contentInset 下发：WebView frame 全屏延伸到物理底边，内容
    /// 透过液态玻璃 chrome 渲染；fixed 底部元素锚定与滚动停留边界同时避让
    /// chrome 区（对齐 Safari）
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
        container.bottomInset = bottomInset
        // 无条件重设：键盘弹起/收起时 WebKit 会覆写内部 inset，保证最终与 chrome 一致
        container.applyChromeInsets()
    }
}

/// Safari 式原生层安全区：WebView 的 frame 只让开顶部安全区（状态栏染色层绘制），
/// 底部一路延伸到物理屏幕底边，内容透过液态玻璃工具栏渲染、不被底色遮住。
/// 底部避让走公开 API：scrollView.contentInset.bottom = chrome 高度，
/// contentInsetAdjustmentBehavior = .never（工厂创建时设置）防止系统自动 inset
/// 双重叠加；fixed 元素锚定与滚动停留边界由 WebKit 据此调整。
final class BrowserContainerView: UIView {
    var bottomInset: CGFloat = 0 {
        didSet {
            guard oldValue != bottomInset else { return }
            applyChromeInsets()
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
        let height = max(bounds.height - topInset, 0)
        webView.frame = CGRect(x: 0, y: safeAreaInsets.top, width: bounds.width, height: height)
        applyChromeInsets()
    }

    /// 底部避让下发入口：inset 驱动 fixed 元素锚定与滚动范围；
    /// 兜底隐藏 iOS 26 边缘填充视图，保证玻璃下透出实时内容
    func applyChromeInsets() {
        guard let webView = subviews.first as? WKWebView else {
            return
        }
        applyBottomInset(to: webView)
        hideColorExtensionViews(in: webView)
    }

    /// contentInset 随 chrome 显隐 / 键盘高度 0.2s 动画同步（对齐 Safari 底栏滑动）
    private func applyBottomInset(to webView: WKWebView) {
        let scrollView = webView.scrollView
        guard scrollView.contentInset.bottom != bottomInset else {
            return
        }
        let update = {
            scrollView.contentInset.bottom = self.bottomInset
            scrollView.verticalScrollIndicatorInsets.bottom = self.bottomInset
        }
        if window != nil {
            UIView.animate(withDuration: 0.2, animations: update)
        } else {
            update()
        }
    }

    /// iOS 26 边缘色填充视图（WKColorExtensionView）会把 chrome 区底下的实时页面
    /// 内容盖成不透明色块；隐藏后透出实时内容（对齐 Safari 玻璃下可见内容的观感）。
    /// 只隐藏底部延伸视图：顶部延伸视图承担页面顶色向状态栏方向/橡皮筋回弹区域的
    /// 连续填充，是顶部染色的一部分，不能动。WebKit 在 inset 边集合变化时会重建
    /// 这些视图，故每次下发时兜底隐藏一次即可。
    private func hideColorExtensionViews(in webView: WKWebView) {
        guard let extensionClass = NSClassFromString("WKColorExtensionView") else {
            return
        }
        for subview in webView.scrollView.subviews
        where subview.isKind(of: extensionClass) && bottomEdgeExtension(subview, in: webView.scrollView) {
            subview.isHidden = true
        }
    }

    /// 底部延伸视图位于内容底边及以下；顶部延伸视图在内容顶边以上（frame.maxY ≈ 0），
    /// 依此区分两端，阈值留 1pt 容差
    private func bottomEdgeExtension(_ view: UIView, in scrollView: UIScrollView) -> Bool {
        let contentBottom = max(scrollView.contentSize.height, scrollView.bounds.height)
        return view.frame.minY >= contentBottom - 1
    }
}
