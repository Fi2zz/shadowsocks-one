import SwiftUI
import WebKit

/// `_setObscuredInsets:` / `_setUnobscuredSafeAreaInsets:` 的 C 调用约定签名
/// （UIEdgeInsets 结构体参数，无法走 perform/KVC）
private typealias EdgeInsetsSetter = @convention(c) (AnyObject, Selector, UIEdgeInsets) -> Void

/// 只负责把 TabManager 缓存中的 WebView 挂到容器上，绝不创建。
/// tabID 变化时 SwiftUI 调 updateUIViewController，在此换挂接对象；容器本身复用，
/// WebView 不因视图重建 / fullScreenCover 弹出而销毁，页面状态得以保留。
struct BrowserWebViewContainer: UIViewControllerRepresentable {
    let tabID: UUID
    /// 底部 chrome 区总高（展开 = 工具栏 + 底部安全区；收起 = 胶囊 + 底部安全区，
    /// 键盘在时 = 键盘 + 工具栏）。显隐动画同步（design.md §4.1）
    let bottomInset: CGFloat

    func makeUIViewController(context: Context) -> BrowserChromeViewController {
        let controller = BrowserChromeViewController()
        controller.chromeInset = bottomInset
        return controller
    }

    func updateUIViewController(_ controller: BrowserChromeViewController, context: Context) {
        controller.attach(BrowserTabManager.shared.webView(for: tabID))
        controller.chromeInset = bottomInset
    }
}

/// Safari 式 chrome/内容分离：WebView frame 全屏（延伸到状态栏与物理底边），
/// 顶部状态栏区域不放任何原生视图；chrome 避让双通道下发：
/// 1. 公开通道——子 VC additionalSafeAreaInsets 抬高 WebView 有效安全区
///    （顶部 = 真实状态栏高，底部 = chrome 总高），WebKit 遮挡/安全区推导的基线；
/// 2. WebKit 显式 inset——实测 iOS 26 上 WKWebView 不会自发消费安全区进入页面
///    （env/布局视口均不变），需经 `_setObscuredInsets:`（fixed 元素布局视口）
///    与 `_setUnobscuredSafeAreaInsets:`（env 上报值）显式下发。
final class BrowserChromeViewController: UIViewController {
    var chromeInset: CGFloat = 0 {
        didSet {
            guard oldValue != chromeInset else { return }
            applyChromeInsets()
        }
    }

    override func loadView() {
        view = BrowserContainerView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyChromeInsets()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyChromeInsets()
    }

    func attach(_ webView: WKWebView) {
        guard let container = view as? BrowserContainerView else { return }
        container.attach(webView)
        applyChromeInsets()
    }

    /// 目标有效安全区：顶部 = 真实状态栏高（SwiftUI ignoresSafeArea 消费安全区时
    /// 继承值为 0，window 值始终正确），底部 = chrome 总高。
    /// 追加值 = 目标 − 继承值（继承值 = 当前有效值 − 已追加值，排除自身避免振荡）；
    /// 仅在变化时写入，避免每次布局都触发 WebKit 安全区重算
    private func applyChromeInsets() {
        applySafeAreaInsets()
        applyWebKitInsets()
    }

    private func applySafeAreaInsets() {
        let inheritedTop = view.safeAreaInsets.top - additionalSafeAreaInsets.top
        let inheritedBottom = view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom
        let target = UIEdgeInsets(
            top: max(0, realTopInset - inheritedTop),
            left: 0,
            bottom: max(0, chromeInset - inheritedBottom),
            right: 0
        )
        guard additionalSafeAreaInsets != target else { return }
        additionalSafeAreaInsets = target
    }

    /// 显式 inset 与安全区目标一致：obscured 驱动 fixed 元素布局视口与滚动范围，
    /// unobscuredSafeArea 驱动页面 env(safe-area-inset-*) 上报值；
    /// 与 safe-area 通道同样仅在变化时写入（viewDidLayoutSubviews 每次布局都会走到这里）
    private func applyWebKitInsets() {
        guard let webView = view.subviews.first as? WKWebView else { return }
        let top = realTopInset
        let unchanged = lastWebKitInset?.top == top
            && lastWebKitInset?.bottom == chromeInset
            && lastInsetTarget === webView
        guard !unchanged else { return }
        let insets = UIEdgeInsets(top: 0, left: 0, bottom: chromeInset, right: 0)
        Self.setEdgeInsets(insets, on: webView, setter: "_setObscuredInsets:")
        let unobscured = UIEdgeInsets(top: top, left: 0, bottom: chromeInset, right: 0)
        Self.setEdgeInsets(unobscured, on: webView, setter: "_setUnobscuredSafeAreaInsets:")
        lastWebKitInset = (top: top, bottom: chromeInset)
        lastInsetTarget = webView
    }

    private var lastWebKitInset: (top: CGFloat, bottom: CGFloat)?
    private weak var lastInsetTarget: WKWebView?

    private var realTopInset: CGFloat {
        view.window?.safeAreaInsets.top ?? 0
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

/// 容器视图：全屏挂载 WebView，不做任何 inset 计算
/// （chrome 避让全部由 BrowserChromeViewController 下发）
final class BrowserContainerView: UIView {
    /// 换挂 TabManager 缓存中的 WebView：先移除旧对象再挂新对象；
    /// frame 全屏，cover 页头部自己延伸进状态栏，正文延伸到物理底边
    func attach(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
    }
}
