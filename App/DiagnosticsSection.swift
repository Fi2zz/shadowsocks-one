import SharedCore
import SwiftUI

/// 展示 Packet Tunnel 扩展写入共享容器的诊断日志，用于真机排障。
struct DiagnosticsSection: View {
    @State private var lines: [String] = []
    private let store = try? TunnelDiagnosticsStore(
        appGroupID: SharedContainerSettings.appGroupID
    )

    var body: some View {
        Section("隧道诊断") {
            if lines.isEmpty {
                Text("暂无日志。连接 VPN 产生流量后点「刷新」。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(lines.suffix(40).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }

            HStack {
                Button("刷新", action: reload)
                Spacer()
                Button("清空", role: .destructive, action: clear)
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        lines = store?.snapshot() ?? []
    }

    private func clear() {
        store?.clear()
        reload()
    }
}
