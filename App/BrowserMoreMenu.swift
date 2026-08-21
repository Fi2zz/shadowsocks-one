import SwiftUI

struct BrowserMoreMenu: View {
    @ObservedObject var viewModel: RootViewModel
    @ObservedObject var routingViewModel: RoutingViewModel
    @ObservedObject var ipListViewModel: IPListViewModel
    @ObservedObject var tabManager: BrowserTabManager
    let openHistoryURL: (URL) -> Void

    @State private var destination: Destination?

    private enum Destination: Identifiable {
        case tabs
        case history
        case nodePicker
        case importing

        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("浏览器") {
                    Button { destination = .tabs } label: {
                        Label("标签页", systemImage: "square.on.square")
                    }
                    Button { destination = .history } label: {
                        Label("历史记录", systemImage: "clock")
                    }
                }
                VPNControlSection(viewModel: viewModel) {
                    destination = .nodePicker
                }
                Section("分流") {
                    Button { destination = .importing } label: {
                        Label("导入与分流", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .navigationTitle("更多")
        }
        .sheet(item: $destination, content: destinationView)
    }

    @ViewBuilder
    private func destinationView(_ destination: Destination) -> some View {
        switch destination {
        case .tabs:
            BrowserTabOverview(tabManager: tabManager)
        case .history:
            NavigationStack {
                BrowserHistoryView(tabManager: tabManager, openURL: openHistoryURL)
            }
        case .nodePicker:
            NodePickerSheet(viewModel: viewModel)
        case .importing:
            ImportTabView(
                viewModel: viewModel,
                routingViewModel: routingViewModel,
                ipListViewModel: ipListViewModel
            )
        }
    }
}
