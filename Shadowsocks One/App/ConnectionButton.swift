import SharedCore
import SwiftUI

struct ConnectionButton: View {
    private static let teal = Color(red: 0.298, green: 0.761, blue: 0.686)

    let state: ConnectionState
    let action: () -> Void

    private var connected: Bool {
        if case .connected = state {
            return true
        }
        return false
    }

    private var connecting: Bool {
        if case .connecting = state {
            return true
        }
        return false
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(connected ? Self.teal : .white)
                    .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
                Circle()
                    .stroke(.black.opacity(0.06), lineWidth: 1)

                VStack(spacing: 14) {
                    Image(systemName: "power")
                        .font(.system(size: 42, weight: .semibold))
                    Text(connected ? "点击断开" : "点击连接")
                        .font(.headline)
                }
                .foregroundStyle(connected ? .white : Self.teal)
            }
            .frame(width: 200, height: 200)
        }
        .buttonStyle(.plain)
        .disabled(connecting)
        .opacity(connecting ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.2), value: connected)
    }
}
