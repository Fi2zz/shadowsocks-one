import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = RootViewModel.makeDefault()
    @StateObject private var routingViewModel = RoutingViewModel.makeDefault()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            ProfilesTabView(viewModel: viewModel)
                .tabItem {
                    Label("节点", systemImage: "network")
                }

            ImportTabView(viewModel: viewModel)
                .tabItem {
                    Label("导入", systemImage: "square.and.arrow.down")
                }

            RoutingTabView(viewModel: routingViewModel)
                .tabItem {
                    Label("分流", systemImage: "arrow.triangle.branch")
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
