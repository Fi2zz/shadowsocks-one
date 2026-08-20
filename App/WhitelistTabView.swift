import SwiftUI

struct WhitelistTabView: View {
    @ObservedObject var viewModel: WhitelistViewModel

    private var newEntryEmpty: Bool {
        viewModel.newEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("example.com 或 *.example.com", text: $viewModel.newEntry)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit(viewModel.addEntry)
                        Button("添加", action: viewModel.addEntry)
                            .disabled(newEntryEmpty)
                    }
                } header: {
                    Text("添加域名")
                }

                Section {
                    ForEach(viewModel.domains, id: \.self) { domain in
                        Text(domain)
                    }
                    .onDelete(perform: viewModel.deleteEntries)
                } header: {
                    Text("白名单")
                }

                MessageSection(message: viewModel.message)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("白名单")
        }
    }
}

#Preview {
    WhitelistTabView(viewModel: WhitelistViewModel(store: nil))
}
