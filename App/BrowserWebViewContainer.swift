import SwiftUI
import WebKit

/// `_setObscuredInsets:` / `_setUnobscuredSafeAreaInsets:` 的 C 调用约定签名
/// （UIEdgeInsets 结构体参数，无法走 perform/KVC）
private typealias EdgeInsetsSetter = @convention(c) (AnyObject, Selector, UIEdgeInsets) -> Void

/// 只负责把 TabManager 缓存中的 WebView 挂到容器上，绝不创建。
/// tabID 变化时 SwiftUI 调 updateUIView，在此换挂接对象；容器视图本身复用，
/// WebView 不因视图重建 / fullScreenCover 弹出而销毁，页面状态得以保留。
struct BrowserWebViewContainer: UIViewRepresentable {
    let tabID: UUID
    /// 底部 chrome 区高度（展开 = 工具栏 + 底部安全区；收起 = 胶囊 + 底部安全区）。
    /// 经容器的 obscured inset 下发给 WebKit：内容渲染到物理底部、透过液态玻璃
    /// chrome 可见，fixed 底部元素与滚动范围同时避让 chrome 区（对齐 Safari）
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
/// bottomInset 经 WebKit 内部 inset 机制下发，滚动范围与页面安全区由 WebKit 同步处理。
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

    /// Safari 底栏避让在 iOS 26 由两个 WebKit 内部 inset 共同实现：
    /// `_obscuredInsets` 驱动滚动范围与边缘颜色填充；`_unobscuredSafeAreaInsets`
    /// 决定页面 env(safe-area-inset-bottom) 的上报值与 fixed 元素的布局视口，
    /// QQ 新闻等 fixed 横幅据此停在 chrome 上方。
    /// REASON: 公开 API 无等价能力——scrollView.contentInset 只改滚动停留边界，
    /// 不影响 fixed 布局视口与 env 上报（4a4a6b5 已验证并放弃该路线）；
    /// KVC/NSInvocation 在 Swift 侧不可达这些 setter，只能取 IMP 直接调用；
    /// 若上架 App Store 需评估审核风险，届时回退为 frame 裁剪方案。
    /// 方法不存在时（未来系统移除）降级为无避让，不崩溃。
    func applyChromeInsets() {
        guard let webView = subviews.first as? WKWebView else {
            return
        }
        let insets = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        Self.setEdgeInsets(insets, on: webView, setter: "_setObscuredInsets:")
        Self.setEdgeInsets(insets, on: webView, setter: "_setUnobscuredSafeAreaInsets:")
        hideColorExtensionViews(in: webView)
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

    private static func setEdgeInsets(_ insets: UIEdgeInsets, on webView: WKWebView, setter name: String) {
        let selector = NSSelectorFromString(name)
        guard webView.responds(to: selector),
              let method = class_getInstanceMethod(WKWebView.self, selector)
        else {
            return
        }
        let imp = unsafeBitCast(method_getImplementation(method), to: EdgeInsetsSetter.self)
        imp(webView, selector, insets)
    }
}
