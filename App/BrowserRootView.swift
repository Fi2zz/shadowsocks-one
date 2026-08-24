import SwiftUI

struct BrowserRootView: View {
    @ObservedObject var viewModel: RootViewModel
    @ObservedObject var routingViewModel: RoutingViewModel
    @ObservedObject var ipListViewModel: IPListViewModel
    @ObservedObject var hudunSession: HudunSessionViewModel

    @StateObject private var tabManager = BrowserTabManager.makeDefault()
    @State private var morePresented = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                tabWebViews
                bottomContent(safeBottom: proxy.safeAreaInsets.bottom)
            }
            .background(Color(uiColor: .systemBackground))
            // 容器安全区全部穿透（顶部内容画到状态栏后面，对齐 Safari）；
            // 键盘区域必须保留，否则键盘避让失效、输入框被键盘盖住
            .ignoresSafeArea(.container)
            .animation(.easeOut(duration: 0.25), value: tabManager.selectedTab?.progress)
            .animation(.easeInOut(duration: 0.2), value: tabManager.selectedTab?.toolbarCollapsed)
        }
        .overlay(alignment: .top) { loadErrorBanner }
        .sheet(isPresented: $morePresented) { moreMenu }
    }

    /// 展开态贴在安全区上沿；收缩胶囊沉到安全区之下（Home 指示条区域）
    @ViewBuilder
    private func bottomContent(safeBottom: CGFloat) -> some View {
        if tabManager.selectedTab?.toolbarCollapsed == true {
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
            tabManager.selectedTab?.expandToolbar()
        } label: {
            Text(tabManager.selectedTab?.currentURL?.host ?? "")
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
        if let error = tabManager.selectedTab?.loadError {
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
        if let progress = tabManager.selectedTab?.progress, progress > 0, progress < 1 {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(maxWidth: .infinity)
                .scaleEffect(x: 1, y: 2, anchor: .center)
                .padding(.horizontal, 12)
        }
    }

    private var tabWebViews: some View {
        ZStack {
            ForEach(tabManager.tabs) { tab in
                WebViewRepresentable(store: tab)
                    .opacity(tab.id == tabManager.selectedTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == tabManager.selectedTabID)
            }
        }
    }

    private var toolbar: some View {
        BrowserToolbar(
            tabManager: tabManager,
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
            openHistoryURL: openHistoryURL
        )
        .presentationDetents([.medium, .large])
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
