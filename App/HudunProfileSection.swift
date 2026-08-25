import SwiftUI

/// 已登录态：资料与退出登录（线路统一在「节点」选择页管理）。
struct HudunProfileSection: View {
    @ObservedObject var session: HudunSessionViewModel
    @State private var confirmSignOut = false

    var body: some View {
        accountRows
        signOutRows
    }

    @ViewBuilder
    private var accountRows: some View {
        Section("账户信息") {
            if let account = session.account {
                infoRow("UID", account.uid)
                infoRow("手机号", account.phone)
                infoRow("到期时间", account.expireText)
                infoRow("VIP 到期", account.vipExpireText)
                infoRow("设备", account.deviceText)
            } else if session.busy {
                ProgressView()
            }
            Button("刷新资料") {
                Task { await session.reloadAccount() }
            }
            .disabled(session.busy)
        }
    }

    private var signOutRows: some View {
        Section {
            Button("退出登录", role: .destructive) {
                confirmSignOut = true
            }
            .disabled(session.busy)
            MessageSection(message: session.message)
        }
        .confirmationDialog(
            "确定退出当前账号？",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) { session.logout() }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
    }
}
