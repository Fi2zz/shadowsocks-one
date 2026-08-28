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
            rootStack(safeTop: proxy.safeAreaInsets.top, safeBottom: proxy.safeAreaInsets.bottom)
                .background(Color(uiColor: .systemBackground))
                .background(BrowserStatusBarGate(prefersLightText: prefersLightStatusText))
                .animation(.easeOut(duration: 0.25), value: browser.progress)
                .animation(.easeInOut(duration: 0.2), value: browser.toolbarCollapsed)
                .animation(.easeInOut(duration: 0.2), value: browser.pageTint)
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
    }

    /// UI 自动化钩子：`-SSBrowserAutoFocus 1` 启动 1 秒后聚焦地址栏（验证键盘避让用）
    private func autoFocusAddressBarIfNeeded() {
        guard UserDefaults.standard.string(forKey: "SSBrowserAutoFocus") != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            addressFocused = true
        }
    }

    private func rootStack(safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        let bottomChrome = bottomChromeHeight(safeBottom: safeBottom)
        return ZStack(alignment: .bottom) {
            webViewLayer(bottomInset: bottomChrome)
            chromeTint(height: safeTop)
            bottomChromeTint(height: bottomChrome)
            bottomContent(safeBottom: safeBottom)
        }
        // 容器安全区全部穿透（顶部内容画到状态栏后面，对齐 Safari）；
        // 键盘安全区一并忽略：系统键盘安全区对第三方键盘不生效（iOS 26.6 实测），
        // 底栏键盘避让统一由 KeyboardHeightObserver 手动垫高，防止双重叠加
        .ignoresSafeArea([.container, .keyboard])
        .onChange(of: tabManager.activeTabID) { _ in
            browser.observeActiveWebView()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                tabManager.persistAll()
            }
        }
    }

    /// 底部 chrome 区 = 工具栏区 + 底部安全区；工具栏收起时归零（内容沉到
    /// Home 指示条后面，对应 Safari 底栏收起态）
    private func bottomChromeHeight(safeBottom: CGFloat) -> CGFloat {
        browser.toolbarCollapsed ? 0 : safeBottom + 60
    }

    /// 状态栏区域染色层：页面顶色（Safari 探针算法）延伸到状态栏背后
    @ViewBuilder
    private func chromeTint(height: CGFloat) -> some View {
        if height > 0 {
            Rectangle()
                .fill(tintColor)
                .frame(height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
    }

    /// 底部 chrome 区染色层：页面底边色延伸到工具栏背后（Safari 对底栏区域做同样的事）
    @ViewBuilder
    private func bottomChromeTint(height: CGFloat) -> some View {
        if height > 0 {
            Rectangle()
                .fill(bottomTintColor)
                .frame(height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var resolvedTint: BrowserPageTint? {
        browser.pageTint?.resolved(over: systemBackgroundTint)
    }

    private var resolvedBottomTint: BrowserPageTint? {
        browser.pageBottomTint?.resolved(over: systemBackgroundTint)
    }

    private var tintColor: Color {
        color(of: resolvedTint)
    }

    private var bottomTintColor: Color {
        color(of: resolvedBottomTint)
    }

    private func color(of tint: BrowserPageTint?) -> Color {
        guard let tint else {
            return Color(uiColor: .systemBackground)
        }
        return Color(.sRGB, red: tint.red / 255, green: tint.green / 255, blue: tint.blue / 255)
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

    /// 收缩胶囊沉到安全区之下（Home 指示条区域）；展开态由键盘观察者手动垫高
    @ViewBuilder
    private func bottomContent(safeBottom: CGFloat) -> some View {
        if browser.toolbarCollapsed {
            compactPill
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            expandedBottomArea(safeBottom: safeBottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func expandedBottomArea(safeBottom: CGFloat) -> some View {
        VStack(spacing: 4) {
            loadingProgressBar
            toolbar
        }
        // 键盘在时垫键盘高度（键盘已占据 Home 指示条区域），否则垫底部安全区
        .padding(.bottom, keyboard.height > 0 ? keyboard.height + 4 : safeBottom + 4)
        .animation(keyboard.animation, value: keyboard.height)
    }

    private var compactPill: some View {
        Button {
            browser.expandToolbar()
        } label: {
            Text(browser.activePageURL?.host ?? "")
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .liquidGlassCapsule()
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
