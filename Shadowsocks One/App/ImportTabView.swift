import SwiftUI

struct ImportTabView: View {
    @ObservedObject var viewModel: RootViewModel

    var body: some View {
        NavigationStack {
            List {
                ImportSection(
                    rawURL: $viewModel.rawURL,
                    importAction: viewModel.importProfile
                )

                MessageSection(message: viewModel.message)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("导入节点")
        }
    }
}
