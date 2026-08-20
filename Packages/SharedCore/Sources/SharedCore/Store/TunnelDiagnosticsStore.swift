import Foundation

/// 隧道诊断环形日志：扩展侧追加、App 侧展示，用于真机排障。
/// 只记录会话级事件（DNS 决策、TCP/UDP 新会话、失败与超时），不记逐包事件。
public final class TunnelDiagnosticsStore: @unchecked Sendable {
    private enum Keys {
        static let entries = "packetTunnel.diagnostics"
    }

    private let capacity: Int
    private let userDefaults: UserDefaults
    private let lock = NSLock()

    public init(appGroupID: String, capacity: Int = 200) throws {
        guard let userDefaults = UserDefaults(suiteName: appGroupID) else {
            throw CocoaError(.fileNoSuchFile)
        }

        self.userDefaults = userDefaults
        self.capacity = capacity
    }

    init(userDefaults: UserDefaults, capacity: Int = 200) {
        self.userDefaults = userDefaults
        self.capacity = capacity
    }

    public func append(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)"

        lock.lock()
        var lines = userDefaults.stringArray(forKey: Keys.entries) ?? []
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        userDefaults.set(lines, forKey: Keys.entries)
        lock.unlock()
    }

    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return userDefaults.stringArray(forKey: Keys.entries) ?? []
    }

    public func clear() {
        lock.lock()
        userDefaults.removeObject(forKey: Keys.entries)
        lock.unlock()
    }
}
