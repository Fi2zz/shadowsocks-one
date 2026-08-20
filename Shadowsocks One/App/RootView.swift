import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = RootViewModel.makeDefault()

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
        }
    }
}

#Preview {
    RootView()
}
