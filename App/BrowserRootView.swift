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
                .animation(.spring(response: 0.3, dampingFraction: 0.9), value: browser.toolbarCollapsed)
        }
        .overlay(alignment: .top) { loadErrorBanner }
        .fullScreenCover(isPresented: $browser.showSwitcher) {
            BrowserTabSwitcherView()
        }
        .overlay(alignment: .bottom) { backgroundToast }
        .sheet(isPresented: $morePresented) { moreMenu }
        // 第三方键盘（微信键盘）会生成残缺的键盘安全区（实测约 136pt，远小于实际
        // 424pt），在根层级忽略，底栏避让完全交给 KeyboardHeightObserver 手动计算
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear(perform: autoFocusAddressBarIfNeeded)
        .onAppear(perform: openURLIfRequested)
        .onAppear(perform: scrollIfRequested)
    }

    /// UI 自动化钩子：`-SSBrowserOpenURL <url>` 启动后直接打开指定页面（布局验证用）
    private func openURLIfRequested() {
        guard let raw = UserDefaults.standard.string(forKey: "SSBrowserOpenURL"),
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
        guard let raw = UserDefaults.standard.string(forKey: "SSBrowserScrollY"),
              let offset = Double(raw)
        else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            scrollActiveWebView(to: offset)
        }
        guard let raw2 = UserDefaults.standard.string(forKey: "SSBrowserScrollY2"),
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
        guard UserDefaults.standard.string(forKey: "SSBrowserAutoFocus") != nil else { return }
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
            // 不加 .id(tabID)：那会销毁重建 representable，容器本身要复用
            BrowserWebViewContainer(tabID: tabID, bottomInset: bottomInset)
        }
    }

    /// 底部 chrome 常驻单棵视图树：胶囊身份在展开/收缩间保持不变，
    /// 尺寸/内边距/间距变化全部由 toolbarCollapsed 动画驱动（对齐 Safari 形变手感），
    /// 按钮与进度条随透明度过渡，无容器级 transition
    private func bottomContent(safeBottom: CGFloat) -> some View {
        VStack(spacing: BrowserChromeMetrics.barSpacing) {
            if !browser.toolbarCollapsed {
                loadingProgressBar.transition(.opacity)
            }
            toolbar
        }
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

    @ViewBuilder
    private var loadErrorBanner: some View {
        if let error = browser.loadError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var loadingProgressBar: some View {
        if browser.progress > 0, browser.progress < 1 {
            ProgressView(value: browser.progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(maxWidth: .infinity)
                .scaleEffect(x: 1, y: 2, anchor: .center)
                .padding(.horizontal, 12)
        }
    }

    /// 后台打开提示：3 秒自动消失，「查看」切到新标签
    @ViewBuilder
    private var backgroundToast: some View {
        Group {
            if browser.backgroundToastTabID != nil {
                toastContent
            }
        }
        .animation(.spring(), value: browser.backgroundToastTabID)
    }

    private var toastContent: some View {
        HStack {
            Text("已在后台打开")
                .font(.subheadline)
            Spacer()
            Button("查看", action: browser.viewBackgroundTab)
                .font(.subheadline.bold())
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, browser.toolbarCollapsed ? 70 : 130)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { browser.backgroundToastTabID = nil }
        }
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
