import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = RootViewModel.makeDefault()

    var body: some View {
        NavigationStack {
            List {
                ImportSection(
                    rawURL: $viewModel.rawURL,
                    importAction: viewModel.importProfile
                )

                ProfileListSection(
                    profiles: viewModel.profiles,
                    selectedProfileID: viewModel.selectedProfileID,
                    connectionState: viewModel.connectionState,
                    selectAction: viewModel.selectProfile,
                    connectAction: viewModel.connectSelectedProfile,
                    disconnectAction: viewModel.disconnect
                )

                if let message = viewModel.message {
                    Section("提示") {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Shadowsocks One")
        }
    }
}

#Preview {
    RootView()
}
