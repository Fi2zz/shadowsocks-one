import SharedCore
import SwiftUI

extension ConnectionState {
    var displayText: String {
        switch self {
        case .idle:
            return "未连接"
        case .connecting:
            return "连接中"
        case .connected:
            return "已连接"
        case let .failed(message):
            return "失败：\(message)"
        }
    }

    var allowsConnect: Bool {
        if case .connecting = self {
            return false
        }
        if case .connected = self {
            return false
        }
        return true
    }

    var allowsDisconnect: Bool {
        if case .idle = self {
            return false
        }
        if case .failed = self {
            return false
        }
        return true
    }

    var statusColor: Color {
        switch self {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .idle, .failed:
            return .gray
        }
    }
}
