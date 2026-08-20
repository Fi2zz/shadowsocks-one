import SwiftUI

struct ProfilesTabView: View {
    @ObservedObject var viewModel: RootViewModel
    @State private var pickerPresented = false

    private var failureDetail: String? {
        if case let .failed(detail) = viewModel.connectionState {
            return detail
        }
        return nil
    }

    private var pickerTitle: String {
        viewModel.selectedProfile?.displayName ?? "选择节点"
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack {
                Image("WorldMapDots")
                    .resizable()
                    .scaledToFit()
                Spacer()
            }
            .ignoresSafeArea(edges: .top)

            VStack(spacing: 28) {
                Spacer()
                ConnectionButton(
                    state: viewModel.connectionState,
                    action: toggleConnection
                )
                if let failureDetail {
                    Text(failureDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
                ProfilePickerBar(title: pickerTitle) {
                    pickerPresented = true
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $pickerPresented) {
            ProfilePickerSheet(viewModel: viewModel)
        }
    }

    private func toggleConnection() {
        if viewModel.connectionState.allowsDisconnect {
            viewModel.disconnect()
            return
        }
        guard viewModel.selectedProfile != nil else {
            pickerPresented = true
            return
        }
        viewModel.connectSelectedProfile()
    }
}
