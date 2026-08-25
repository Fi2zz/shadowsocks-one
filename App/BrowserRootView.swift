import SharedCore
import SwiftUI
import UIKit

struct BrowserRootView: View {
    @ObservedObject var viewModel: RootViewModel
    @ObservedObject var routingViewModel: RoutingViewModel
    @ObservedObject var ipListViewModel: IPListViewModel
    @ObservedObject var hudunSession: HudunSessionViewModel

    @StateObject private var browser = BrowserViewModel()
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
    }

    private func rootStack(safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            webViewLayer
            chromeTint(height: safeTop)
            bottomContent(safeBottom: safeBottom)
        }
        // 容器安全区全部穿透（顶部内容画到状态栏后面，对齐 Safari）；
        // 键盘区域必须保留，否则键盘避让失效、输入框被键盘盖住
        .ignoresSafeArea(.container)
        .onChange(of: tabManager.activeTabID) { _ in
            browser.observeActiveWebView()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                tabManager.persistAll()
            }
        }
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

    private var resolvedTint: BrowserPageTint? {
        browser.pageTint?.resolved(over: systemBackgroundTint)
    }

    private var tintColor: Color {
        guard let tint = resolvedTint else {
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
    private var webViewLayer: some View {
        if let tabID = tabManager.activeTabID {
            // 不加 .id(tabID)：那会销毁重建 representable，容器本身要复用
            BrowserWebViewContainer(tabID: tabID)
        }
    }

    /// 展开态贴在安全区上沿；收缩胶囊沉到安全区之下（Home 指示条区域）
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
        // 键盘弹起时系统已完成避让，再垫安全区高度会把输入框顶到半空
        .padding(.bottom, addressFocused ? 4 : safeBottom + 4)
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
