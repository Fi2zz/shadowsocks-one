import SwiftUI

/// 线路实时快照（route_list）；点击行取 WG 凭证包（route_info）。
struct HudunLineListSection: View {
    private struct ConfigBox: Identifiable {
        let id = UUID()
        let config: HudunWGConfig
    }

    @ObservedObject var session: HudunSessionViewModel
    @State private var presentedConfig: ConfigBox?

    var body: some View {
        Section("线路") {
            lineRows
            refreshButton
        }
        .sheet(item: $presentedConfig) { box in
            HudunWGConfSheet(config: box.config)
        }
    }

    @ViewBuilder
    private var lineRows: some View {
        if session.lines.isEmpty {
            Text(session.busy ? "加载中…" : "暂无线路")
                .foregroundStyle(.secondary)
        } else {
            ForEach(sortedLines) { line in
                rowButton(line)
            }
        }
    }

    private var sortedLines: [HudunLine] {
        session.lines.sorted { rank($0.tier) < rank($1.tier) }
    }

    private func rank(_ tier: String) -> Int {
        tier == "svip" ? 0 : 1
    }

    private func rowButton(_ line: HudunLine) -> some View {
        Button {
            fetchConfig(lineID: line.id)
        } label: {
            rowLabel(line)
        }
        .buttonStyle(.plain)
        .disabled(line.isBlocked || session.busy)
    }

    private func rowLabel(_ line: HudunLine) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name).foregroundStyle(.primary)
                Text("\(tierLabel(line.tier)) · \(line.typeName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if line.isBlocked {
                Text("维护中").font(.caption).foregroundStyle(.red)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func tierLabel(_ tier: String) -> String {
        tier.uppercased()
    }

    private var refreshButton: some View {
        Button("刷新线路") {
            Task { await session.refreshLines() }
        }
        .disabled(session.busy)
    }

    private func fetchConfig(lineID: Int) {
        Task {
            guard let config = await session.renew(lineId: lineID) else { return }
            presentedConfig = ConfigBox(config: config)
        }
    }
}
