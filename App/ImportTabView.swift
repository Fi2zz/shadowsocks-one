import SwiftUI

struct ImportTabView: View {
    @ObservedObject var viewModel: RootViewModel
    @ObservedObject var routingViewModel: RoutingViewModel
    @ObservedObject var ipListViewModel: IPListViewModel

    var body: some View {
        NavigationStack {
            List {
                ImportSection(
                    rawURL: $viewModel.rawURL,
                    importAction: viewModel.importProfile
                )

                RoutingSections(
                    viewModel: routingViewModel,
                    ipListViewModel: ipListViewModel
                )

                MessageSection(message: viewModel.message)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("导入与分流")
        }
    }
}
