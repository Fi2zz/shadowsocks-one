import SwiftUI

struct ProfilePickerSheet: View {
    @ObservedObject var viewModel: RootViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.profiles) { profile in
                    Button {
                        viewModel.selectProfile(id: profile.id)
                        dismiss()
                    } label: {
                        ProfileRow(
                            profile: profile,
                            selected: profile.id == viewModel.selectedProfileID
                        )
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    offsets
                        .map { viewModel.profiles[$0].id }
                        .forEach(viewModel.deleteProfile)
                }
            }
            .navigationTitle("选择节点")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
