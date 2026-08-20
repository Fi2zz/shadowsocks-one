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
                Circle()
                    .stroke(.black.opacity(0.06), lineWidth: 1)

                VStack(spacing: 14) {
                    if connecting {
                        ProgressView()
                            .controlSize(.large)
                            .frame(height: 50)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 42, weight: .semibold))
                    }
                    Text(buttonTitle)
                        .font(.headline)
                }
                .foregroundStyle(connected ? .white : Self.teal)
            }
            .frame(width: 200, height: 200)
        }
        .buttonStyle(.plain)
        .disabled(connecting)
        .animation(.easeInOut(duration: 0.2), value: connected)
        .animation(.easeInOut(duration: 0.2), value: connecting)
    }

    private var buttonTitle: String {
        if connecting {
            return "连接中…"
        }
        return connected ? "点击断开" : "点击连接"
    }
}
