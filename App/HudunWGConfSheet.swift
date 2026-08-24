import SwiftUI
import UIKit

/// renew 返回的 WG 凭证包展示（confString 可复制导入官方客户端）。
struct HudunWGConfSheet: View {
    let config: HudunWGConfig
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("节点") {
                    kvRow("Endpoint", config.endpoint)
                    kvRow("有效期至", expiryText)
                    kvRow("DNS", config.dns)
                    kvRow("MTU", String(config.mtu))
                }
                Section("WireGuard 配置") {
                    Text(config.confString)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("隧道配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    copyButton
                }
            }
        }
    }

    private var expiryText: String {
        guard let expiry = config.expiresAt else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: expiry)
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = config.confString
            copied = true
        } label: {
            Label(
                copied ? "已复制" : "复制",
                systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }

    private func kvRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary).textSelection(.enabled)
        }
    }
}
