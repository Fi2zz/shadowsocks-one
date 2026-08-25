import SharedCore
import SwiftUI

/// 统一节点选择页：SS 节点与护盾线路并列；点行仅勾选，不触发连接。
struct NodePickerSheet: View {
    @ObservedObject var viewModel: RootViewModel
    @ObservedObject var hudunSession: HudunSessionViewModel

    var body: some View {
        NavigationStack {
            List {
                ssSection
                hudunSection
            }
            .navigationTitle("选择节点")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Shadowsocks

    private var ssSection: some View {
        Section("Shadowsocks") {
            profileRows
        }
    }

    private var profileRows: some View {
        ForEach(viewModel.profiles) { profile in
            Button {
                selectProfile(profile)
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

    private func selectProfile(_ profile: ServerProfile) {
        hudunSession.clearSelectedLine()
        viewModel.selectProfile(id: profile.id)
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

    // MARK: - 护盾线路

    private var hudunSection: some View {
        Section {
            hudunRows
            refreshRow
        } header: {
            Text("护盾节点")
        } footer: {
            Text(hudunFooter)
        }
    }

    @ViewBuilder
    private var hudunRows: some View {
        if hudunSession.lines.isEmpty {
            Text(hudunSession.busy ? "线路加载中…" : "登录护盾账号后显示线路")
                .foregroundStyle(.secondary)
        } else {
            ForEach(sortedLines) { line in
                hudunRowButton(line)
            }
        }
    }

    private var sortedLines: [HudunLine] {
        hudunSession.lines.sorted { rank($0.tier) < rank($1.tier) }
    }

    private func rank(_ tier: String) -> Int {
        tier == "svip" ? 0 : 1
    }

    private func hudunRowButton(_ line: HudunLine) -> some View {
        Button {
            hudunSession.select(line)
        } label: {
            hudunRowLabel(line)
        }
        .buttonStyle(.plain)
        .disabled(line.isBlocked)
    }

    private func hudunRowLabel(_ line: HudunLine) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name).foregroundStyle(.primary)
                Text(caption(for: line))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hudunSession.selectedLine?.id == line.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func caption(for line: HudunLine) -> String {
        line.isBlocked ? "维护中" : "\(line.tier.uppercased()) · \(line.typeName)"
    }

    private var refreshRow: some View {
        Button {
            Task { await hudunSession.refreshLines() }
        } label: {
            HStack {
                Text("刷新线路")
                if hudunSession.busy {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(hudunSession.busy)
    }

    private var hudunFooter: String {
        if let message = hudunSession.message {
            return message
        }
        return "勾选后不会自动连接，回到「更多」按「连接」生效。"
    }
}
