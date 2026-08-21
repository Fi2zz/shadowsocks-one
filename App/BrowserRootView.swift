import SwiftUI

struct BrowserRootView: View {
    @ObservedObject var viewModel: RootViewModel
    @ObservedObject var routingViewModel: RoutingViewModel
    @ObservedObject var ipListViewModel: IPListViewModel

    @StateObject private var tabManager = BrowserTabManager.makeDefault()
    @State private var morePresented = false

    var body: some View {
        tabWebViews
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .top) { topOverlay }
            .safeAreaInset(edge: .bottom) { toolbar }
            .sheet(isPresented: $morePresented) { moreMenu }
    }

    @ViewBuilder
    private var topOverlay: some View {
        VStack(spacing: 0) {
            loadingProgressBar
            loadErrorBanner
        }
        .animation(.easeOut(duration: 0.25), value: tabManager.selectedTab?.progress)
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
            showMore: { morePresented = true }
        )
    }

    private var moreMenu: some View {
        BrowserMoreMenu(
            viewModel: viewModel,
            routingViewModel: routingViewModel,
            ipListViewModel: ipListViewModel,
            tabManager: tabManager,
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
        ipListViewModel: IPListViewModel.makeDefault()
    )
}
