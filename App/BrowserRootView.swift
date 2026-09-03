import SharedCore
import SwiftUI
import UIKit

struct BrowserRootView: View {
    @ObservedObject var viewModel: RootViewModel
    @ObservedObject var routingViewModel: RoutingViewModel
    @ObservedObject var ipListViewModel: IPListViewModel
    @ObservedObject var hudunSession: HudunSessionViewModel

    @StateObject private var browser = BrowserViewModel()
    @StateObject private var keyboard = KeyboardHeightObserver()
    @ObservedObject private var tabManager = BrowserTabManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var addressFocused: Bool
    @State private var morePresented = false

    var body: some View {
        GeometryReader { proxy in
            rootStack(safeBottom: proxy.safeAreaInsets.bottom)
                .background(Color(uiColor: .systemBackground))
                .background(BrowserStatusBarGate(prefersLightText: prefersLightStatusText))
                .animation(.easeOut(duration: 0.25), value: browser.progress)
                .animation(BrowserChromeMetrics.collapseSpring, value: browser.toolbarCollapsed)
                .animation(BrowserChromeMetrics.tabSlideAnimation, value: tabManager.activeTabID)
        }
        .fullScreenCover(isPresented: $browser.showSwitcher) {
            BrowserTabSwitcherView()
        }
        .sheet(isPresented: $morePresented) { moreMenu }
        // 第三方键盘（微信键盘）会生成残缺的键盘安全区（实测约 136pt，远小于实际
        // 424pt），在根层级忽略，底栏避让完全交给 KeyboardHeightObserver 手动计算
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear(perform: autoFocusAddressBarIfNeeded)
        .onAppear(perform: openURLIfRequested)
        .onAppear(perform: scrollIfRequested)
        .onAppear(perform: forceFoldProgressIfNeeded)
        .onAppear { BrowserBottomProbe.runIfRequested() }
    }

    /// UI 自动化钩子：`-SSBrowserFoldProgress <0..1>` 直接设定折叠形变进度
    /// （形变视觉验证用；滚动钩子只影响布局，不再驱动折叠——折叠只吃用户手势）
    private func forceFoldProgressIfNeeded() {
        guard let raw = BrowserDebugFlags.value(forKey: "SSBrowserFoldProgress"),
              let value = Double(raw)
        else {
            return
        }
        browser.toolbarCollapseProgress = CGFloat(min(1, max(0, value)))
    }

    /// UI 自动化钩子：`-SSBrowserOpenURL <url>` 启动后直接打开指定页面（布局验证用）
    private func openURLIfRequested() {
        guard let raw = BrowserDebugFlags.value(forKey: "SSBrowserOpenURL"),
              let url = URL(string: raw)
        else {
            return
        }
        tabManager.open(url)
    }

    /// UI 自动化钩子：`-SSBrowserScrollY <points>` 启动 3 秒后滚动到指定偏移
    /// （等页面加载与避让 inset 就位；验证滚动态 fixed 元素与折叠动画用）；
    /// 附带 `-SSBrowserScrollY2 <points>` 时 5 秒后再滚到第二偏移（验证回滚行为）
    private func scrollIfRequested() {
        guard let raw = BrowserDebugFlags.value(forKey: "SSBrowserScrollY"),
              let offset = Double(raw)
        else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            scrollActiveWebView(to: offset)
        }
        guard let raw2 = BrowserDebugFlags.value(forKey: "SSBrowserScrollY2"),
              let offset2 = Double(raw2)
        else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            scrollActiveWebView(to: offset2)
        }
    }

    private func scrollActiveWebView(to offset: Double) {
        guard let scrollView = BrowserTabManager.shared.activeWebView?.scrollView
        else { return }
        // 钳到合法范围：iOS 26 的 WebKit scrollView 不即时钳制程序化偏移，
        // 越界传入（如 999999 表示"到底"）会停在内容之外的空白区
        let maxOffset = Double(scrollView.contentSize.height - scrollView.bounds.height
            + scrollView.contentInset.bottom)
        let clamped = min(max(offset, 0), max(0, maxOffset))
        scrollView.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
    }

    /// UI 自动化钩子：`-SSBrowserAutoFocus 1` 启动 1 秒后聚焦地址栏（验证键盘避让用）
    private func autoFocusAddressBarIfNeeded() {
        guard BrowserDebugFlags.value(forKey: "SSBrowserAutoFocus") != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            addressFocused = true
        }
    }

    private func rootStack(safeBottom: CGFloat) -> some View {
        let bottomChrome = browser.bottomChromeHeight(keyboardHeight: keyboard.height)
        return ZStack(alignment: .bottom) {
            webViewLayer(bottomInset: bottomChrome)
            bottomContent(safeBottom: safeBottom)
        }
        // 容器安全区全部穿透：顶部状态栏区域完全交给页面（cover 页自己把
        // 头部画进状态栏，无任何原生染色层，对齐 Safari）；键盘安全区一并
        // 忽略：系统键盘安全区对第三方键盘不生效（iOS 26.6 实测），
        // 底栏键盘避让统一由 KeyboardHeightObserver 手动垫高，防止双重叠加
        .ignoresSafeArea([.container, .keyboard])
        .onAppear { browser.bottomSafeArea = safeBottom }
        .onChange(of: safeBottom) { browser.bottomSafeArea = $0 }
        .onChange(of: tabManager.activeTabID) { _ in
            browser.observeActiveWebView()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                tabManager.persistAll()
            }
        }
    }

    /// 状态栏文字深浅判定：theme-color 优先，其次探针采样的页面顶色
    private var resolvedTint: BrowserPageTint? {
        browser.themeColorTint ?? browser.pageTint?.resolved(over: systemBackgroundTint)
    }

    private var prefersLightStatusText: Bool {
        resolvedTint?.prefersLightStatusBarText ?? false
    }

    private var systemBackgroundTint: BrowserPageTint {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor.systemBackground.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return BrowserPageTint(red: red, green: green, blue: blue, alpha: alpha)
    }

    @ViewBuilder
    private func webViewLayer(bottomInset: CGFloat) -> some View {
        if let tabID = tabManager.activeTabID {
            // .id(tabID) 给每个标签独立身份，驱动滑入/滑出 transition；重建的只是
            // 轻量容器 VC，WebView 本体由 TabManager 缓存持有，页面状态不丢
            BrowserWebViewContainer(tabID: tabID, bottomInset: bottomInset)
                .id(tabID)
                .transition(slideTransition)
        }
    }

    /// Safari 式切换：新页从行进方向滑入，旧页向对侧滑出；
    /// 方向由 TabManager 在改 activeTabID 前写入，切换帧读到的一定是新值
    private var slideTransition: AnyTransition {
        let incoming: Edge = tabManager.slideDirection == .forward ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: incoming),
            removal: .move(edge: incoming == .trailing ? .leading : .trailing)
        )
    }

    /// 底部 chrome 常驻单棵视图树：胶囊身份在展开/收缩间保持不变，
    /// 尺寸/内边距/间距变化全部由 toolbarCollapsed 动画驱动（对齐 Safari 形变手感），
    /// 按钮与进度条随透明度过渡，无容器级 transition
    private func bottomContent(safeBottom: CGFloat) -> some View {
        toolbar
            .padding(.bottom, bottomPadding(safeBottom: safeBottom))
            .animation(keyboard.animation, value: keyboard.height)
    }

    /// 收缩态沉到 Home 指示条区域；展开态贴安全区下缘；键盘在时垫键盘高度
    private func bottomPadding(safeBottom: CGFloat) -> CGFloat {
        if browser.toolbarCollapsed {
            return BrowserChromeMetrics.pillBottomPadding
        }
        return keyboard.height > 0 ? keyboard.height + 4 : safeBottom
    }

    private var toolbar: some View {
        BrowserToolbar(
            tabManager: tabManager,
            browser: browser,
            connectionState: viewModel.connectionState,
            addressFocused: $addressFocused,
            showMore: { morePresented = true }
        )
    }

    private var moreMenu: some View {
        BrowserMoreMenu(
            viewModel: viewModel,
            routingViewModel: routingViewModel,
            ipListViewModel: ipListViewModel,
            tabManager: tabManager,
            hudunSession: hudunSession,
            openHistoryURL: openHistoryURL,
            newTab: newTabFromMenu,
            openSwitcher: openSwitcherFromMenu
        )
        .presentationDetents([.medium, .large])
    }

    /// 收起菜单 → 新建标签 → 对齐 Safari：新标签聚焦地址栏直接可输入
    private func newTabFromMenu() {
        morePresented = false
        browser.createTab()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            addressFocused = true
        }
    }

    /// 先收起 sheet 再弹切换器，避免同视图两级 presentation 抢占
    private func openSwitcherFromMenu() {
        morePresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            browser.showSwitcher = true
        }
    }

    private func openHistoryURL(_ url: URL) {
        morePresented = false
        tabManager.open(url)
    }
}

#Preview {
    BrowserRootView(
        viewModel: RootViewModel.makeDefault(),
        routingViewModel: RoutingViewModel.makeDefault(),
        ipListViewModel: IPListViewModel.makeDefault(),
        hudunSession: HudunSessionViewModel.makeDefault()
    )
}
