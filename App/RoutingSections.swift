import SwiftUI

struct RoutingSections: View {
    @ObservedObject var viewModel: RoutingViewModel
    @ObservedObject var ipListViewModel: IPListViewModel

    var body: some View {
        Group {
            Section {
                Toggle("未命中名单时直连", isOn: directByDefaultBinding)
                Toggle("国内 IP 直连", isOn: bypassCNIPBinding)
            } header: {
                Text("分流")
            } footer: {
                Text("本地/内网 IP 始终直连。「未命中名单时直连」关闭：默认走代理，白名单内域名直连；开启：默认直连，代理名单内域名走代理。名单与开关修改后，下次连接生效。")
            }

            domainSection(for: .direct, title: "白名单（直连）", entry: $viewModel.directEntry)
            domainSection(for: .proxy, title: "代理名单", entry: $viewModel.proxyEntry)

            Section {
                TextField("下载地址", text: $ipListViewModel.sourceURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                HStack {
                    Button(ipListViewModel.updating ? "更新中…" : "立即更新") {
                        Task { await ipListViewModel.update() }
                    }
                    .disabled(ipListViewModel.updating || ipListViewModel.sourceURLEmpty)
                    Spacer()
                    Text(ipListViewModel.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("国内 IP 库")
            } footer: {
                Text("下载的列表存入共享容器，下次连接生效；未下载或下载失败时使用扩展内置列表。")
            }
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
