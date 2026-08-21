import SharedCore
import SwiftUI

struct NodePickerSheet: View {
    @ObservedObject var viewModel: RootViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                profileRows
            }
            .navigationTitle("选择节点")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var profileRows: some View {
        ForEach(viewModel.profiles) { profile in
            Button {
                viewModel.selectProfile(id: profile.id)
                dismiss()
            } label: {
                profileRowLabel(for: profile)
            }
            .buttonStyle(.plain)
        }
        .onDelete { offsets in
            offsets
                .map { viewModel.profiles[$0].id }
                .forEach(viewModel.deleteProfile)
        }
    }

    private func profileRowLabel(for profile: ServerProfile) -> some View {
        HStack {
            Text(profile.displayName)
                .foregroundStyle(.primary)
            Spacer()
            if profile.id == viewModel.selectedProfileID {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
