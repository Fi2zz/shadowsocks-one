import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = RootViewModel.makeDefault()
    @StateObject private var routingViewModel = RoutingViewModel.makeDefault()
    @StateObject private var ipListViewModel = IPListViewModel.makeDefault()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        BrowserRootView(
            viewModel: viewModel,
            routingViewModel: routingViewModel,
            ipListViewModel: ipListViewModel
        )
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                viewModel.refreshTunnelStatus()
                Task {
                    await ipListViewModel.autoUpdateIfNeeded()
                }
            }
        }
    }
}

#Preview {
    RootView()
}
