import SwiftUI

struct ProfilesTabView: View {
    @ObservedObject var viewModel: RootViewModel

    var body: some View {
        NavigationStack {
            List {
                ProfileListSection(
                    profiles: viewModel.profiles,
                    selectedProfileID: viewModel.selectedProfileID,
                    connectionState: viewModel.connectionState,
                    selectAction: viewModel.selectProfile,
                    connectAction: viewModel.connectSelectedProfile,
                    disconnectAction: viewModel.disconnect,
                    deleteAction: viewModel.deleteProfile
                )

                MessageSection(message: viewModel.message)
            }
            .navigationTitle("Shadowsocks One")
        }
    }
}
