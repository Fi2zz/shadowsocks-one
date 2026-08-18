import SharedCore
import SwiftUI

struct ProfileListSection: View {
    let profiles: [ServerProfile]
    let selectedProfileID: UUID?
    let connectionState: ConnectionState
    let selectAction: (UUID) -> Void
    let connectAction: () -> Void
    let disconnectAction: () -> Void

    var body: some View {
        Section("节点") {
            if profiles.isEmpty {
                Text("还没有节点，先导入一个 `ss://`。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profiles) { profile in
                    Button {
                        selectAction(profile.id)
                    } label: {
                        ProfileRow(profile: profile, selected: profile.id == selectedProfileID)
                    }
                    .buttonStyle(.plain)
                }
            }

            LabeledContent("连接状态", value: connectionState.displayText)

            HStack {
                Button("连接", action: connectAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!connectionState.allowsConnect || selectedProfileID == nil)

                Button("断开", action: disconnectAction)
                    .buttonStyle(.bordered)
            }
        }
    }
}
