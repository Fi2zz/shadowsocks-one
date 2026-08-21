import SwiftUI

struct VPNControlSection: View {
    @ObservedObject var viewModel: RootViewModel
    let showPicker: () -> Void

    var body: some View {
        Section {
            connectionRow
            currentNodeRow
        } header: {
            Text("节点")
        } footer: {
            if let message = viewModel.message {
                Text(message)
            }
        }
    }

    private var connectionRow: some View {
        Button(action: toggleConnection) {
            HStack {
                Circle()
                    .fill(viewModel.connectionState.statusColor)
                    .frame(width: 10, height: 10)
                Text(viewModel.connectionState.displayText)
                    .foregroundStyle(.primary)
                Spacer()
                Text(actionTitle)
            }
        }
        .disabled(!connectionToggleable)
    }

    private var actionTitle: String {
        viewModel.connectionState.allowsDisconnect ? "断开" : "连接"
    }

    private var connectionToggleable: Bool {
        viewModel.connectionState.allowsConnect
            || viewModel.connectionState.allowsDisconnect
    }

    private var currentNodeRow: some View {
        Button(action: showPicker) {
            HStack {
                Text("当前节点")
                    .foregroundStyle(.primary)
                Spacer()
                Text(viewModel.selectedProfile?.displayName ?? "未选择")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func toggleConnection() {
        if viewModel.connectionState.allowsDisconnect {
            viewModel.disconnect()
            return
        }
        viewModel.connectSelectedProfile()
    }
}
