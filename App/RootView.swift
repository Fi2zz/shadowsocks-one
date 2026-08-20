import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = RootViewModel.makeDefault()
    @StateObject private var routingViewModel = RoutingViewModel.makeDefault()
    @StateObject private var ipListViewModel = IPListViewModel.makeDefault()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            ProfilesTabView(viewModel: viewModel)
                .tabItem {
                    Label("节点", systemImage: "network")
                }

            ImportTabView(
                viewModel: viewModel,
                routingViewModel: routingViewModel,
                ipListViewModel: ipListViewModel
            )
            .tabItem {
                Label("导入", systemImage: "square.and.arrow.down")
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                viewModel.refreshTunnelStatus()
            }
        }
    }
}

#Preview {
    RootView()
}
