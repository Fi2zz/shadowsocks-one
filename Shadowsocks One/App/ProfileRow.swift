import SharedCore
import SwiftUI

struct ProfileRow: View {
    let profile: ServerProfile
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(selected ? Color.accentColor : Color.secondary.opacity(0.2))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(.headline)
                Text(profile.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}
