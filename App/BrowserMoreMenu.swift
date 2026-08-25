import SwiftUI

struct BrowserMoreMenu: View {
    @ObservedObject var viewModel: RootViewModel
    @ObservedObject var routingViewModel: RoutingViewModel
    @ObservedObject var ipListViewModel: IPListViewModel
    @ObservedObject var tabManager: BrowserTabManager
    @ObservedObject var hudunSession: HudunSessionViewModel
    let openHistoryURL: (URL) -> Void
    let newTab: () -> Void
    let openSwitcher: () -> Void

    @State private var destination: Destination?

    private enum Destination: Identifiable {
        case bookmarks
        case history
        case nodePicker
        case importing
        case account

        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            List {
                browserSection
                VPNControlSection(viewModel: viewModel, hudunSession: hudunSession) {
                    destination = .nodePicker
                }
                Section("账号") {
                    Button { destination = .account } label: {
                        Label("护盾账号", systemImage: "person.crop.circle")
                    }
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

    private var browserSection: some View {
        Section("浏览器") {
            Button(action: newTab) {
                Label("新建标签页", systemImage: "plus")
            }
            Button(action: openSwitcher) {
                Label("标签页", systemImage: "square.on.square")
            }
            Button {
                tabManager.addBookmarkForActivePage()
            } label: {
                Label("添加书签", systemImage: "star")
            }
            .disabled(!tabManager.canBookmarkActivePage)
            Button { destination = .bookmarks } label: {
                Label("书签列表", systemImage: "star.leadinghalf.filled")
            }
            Button { destination = .history } label: {
                Label("历史记录", systemImage: "clock")
            }
            Button(role: .destructive) {
                tabManager.clearBrowsingData()
            } label: {
                Label("清除浏览数据", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: Destination) -> some View {
        switch destination {
        case .bookmarks:
            NavigationStack {
                BrowserBookmarkListView(tabManager: tabManager, openURL: openHistoryURL)
            }
        case .history:
            NavigationStack {
                BrowserHistoryView(tabManager: tabManager, openURL: openHistoryURL)
            }
        case .nodePicker:
            NodePickerSheet(viewModel: viewModel, hudunSession: hudunSession)
        case .importing:
            ImportTabView(
                viewModel: viewModel,
                routingViewModel: routingViewModel,
                ipListViewModel: ipListViewModel
            )
        case .account:
            HudunAccountView(session: hudunSession)
        }
    }
}
