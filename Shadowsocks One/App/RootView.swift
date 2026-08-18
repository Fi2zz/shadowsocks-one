import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Shadowsocks One")
                    .font(.title2.weight(.semibold))
                Text("Packet Tunnel + SharedCore skeleton is ready.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .navigationTitle("Overview")
        }
    }
}

#Preview {
    RootView()
}
