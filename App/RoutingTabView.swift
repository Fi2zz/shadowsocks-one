import SwiftUI

struct RoutingTabView: View {
    @ObservedObject var viewModel: RoutingViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("未命中名单时直连", isOn: directByDefaultBinding)
                    Toggle("国内 IP 直连", isOn: bypassCNIPBinding)
                } footer: {
                    Text("本地/内网 IP 始终直连。「未命中名单时直连」关闭：默认走代理，白名单内域名直连；开启：默认直连，代理名单内域名走代理。")
                }

                domainSection(for: .direct, title: "白名单（直连）", entry: $viewModel.directEntry)
                domainSection(for: .proxy, title: "代理名单", entry: $viewModel.proxyEntry)

                MessageSection(message: viewModel.message)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("分流")
        }
    }

    private var directByDefaultBinding: Binding<Bool> {
        Binding(
            get: { viewModel.directByDefault },
            set: viewModel.setDirectByDefault
        )
    }

    private var bypassCNIPBinding: Binding<Bool> {
        Binding(
            get: { viewModel.bypassCNIP },
            set: viewModel.setBypassCNIP
        )
    }

    private func domainSection(
        for kind: RouteListKind,
        title: String,
        entry: Binding<String>
    ) -> some View {
        Section {
            HStack {
                TextField("example.com 或 *.example.com", text: entry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { viewModel.addEntry(for: kind) }
                Button("添加") { viewModel.addEntry(for: kind) }
                    .disabled(entryEmpty(entry.wrappedValue))
            }

            ForEach(viewModel.domains(for: kind), id: \.self) { domain in
                Text(domain)
            }
            .onDelete { viewModel.deleteEntries(at: $0, for: kind) }
        } header: {
            Text(title)
        }
    }

    private func entryEmpty(_ entry: String) -> Bool {
        entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#Preview {
    RoutingTabView(viewModel: RoutingViewModel(store: nil))
}
