import SwiftUI

struct MessageSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section("提示") {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
