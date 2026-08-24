import SwiftUI

/// 线路实时快照（route_list，缓存回放）；点行即取凭证并连接。
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
            Task { await session.requestConnect(line) }
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
                Text("\(line.tier.uppercased()) · \(line.typeName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailingMark(line)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailingMark(_ line: HudunLine) -> some View {
        if session.connectingLineID == line.id {
            ProgressView().controlSize(.small)
        } else if line.isBlocked {
            Text("维护中").font(.caption).foregroundStyle(.red)
        } else if session.selectedLine?.id == line.id {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
        } else {
            configPeekButton(line)
        }
    }

    private func configPeekButton(_ line: HudunLine) -> some View {
        Button {
            fetchConfig(lineID: line.id)
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
    }

    private var refreshButton: some View {
        Button("刷新线路") {
            Task { await session.refreshLines() }
        }
        .disabled(session.busy)
    }

    private func fetchConfig(lineID: Int) {
        Task {
            if let config = await session.renew(lineId: lineID) {
                presentedConfig = ConfigBox(config: config)
            }
        }
    }
}
