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

                MessageSection(message: mergedMessage)

                RoutingSections(
                    viewModel: routingViewModel,
                    ipListViewModel: ipListViewModel
                )

                DiagnosticsSection()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("导入与分流")
        }
    }

    private var mergedMessage: String? {
        ipListViewModel.message ?? routingViewModel.message ?? viewModel.message
    }
}
