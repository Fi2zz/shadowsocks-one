import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = RootViewModel.makeDefault()
    @StateObject private var routingViewModel = RoutingViewModel.makeDefault()
    @StateObject private var ipListViewModel = IPListViewModel.makeDefault()
    @StateObject private var hudunSession = HudunSessionViewModel.makeDefault()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        BrowserRootView(
            viewModel: viewModel,
            routingViewModel: routingViewModel,
            ipListViewModel: ipListViewModel,
            hudunSession: hudunSession
        )
        .task {
            hudunSession.connectRequestHandler = { [weak viewModel] config, lineID, lineName in
                await viewModel?.hudunTunnels.activate(config, lineID: lineID, lineName: lineName)
            }
        }
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
