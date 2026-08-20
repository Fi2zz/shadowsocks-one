import Foundation

final class UDPSessionStore: @unchecked Sendable {
    struct SessionResult {
        let relay: any UDPFlowRelaying
        let sessionCreated: Bool
        let evictedRelays: [any UDPFlowRelaying]
    }

    private struct Entry {
        let relay: any UDPFlowRelaying
        var lastActiveAt: Date
    }

    private let lock = NSLock()
    private let now: () -> Date
    private let idleTimeout: TimeInterval
    private let capacity: Int
    private var entries: [UDPFlowKey: Entry] = [:]

    init(
        capacity: Int = 256,
        idleTimeout: TimeInterval = 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.capacity = capacity
        self.idleTimeout = idleTimeout
        self.now = now
    }

    func session(
        for key: UDPFlowKey,
        create: () throws -> any UDPFlowRelaying
    ) rethrows -> SessionResult {
        lock.lock()
        defer { lock.unlock() }

        if var entry = entries[key] {
            entry.lastActiveAt = now()
            entries[key] = entry
            return SessionResult(relay: entry.relay, sessionCreated: false, evictedRelays: [])
        }

        let evictedRelays = evictExpired()
        let relay = try create()
        entries[key] = Entry(relay: relay, lastActiveAt: now())
        return SessionResult(
            relay: relay,
            sessionCreated: true,
            evictedRelays: evictedRelays + evictOverflow()
        )
    }

    @discardableResult
    func removeRelay(for key: UDPFlowKey) -> (any UDPFlowRelaying)? {
        lock.lock()
        defer { lock.unlock() }
        return entries.removeValue(forKey: key)?.relay
    }

    func removeAllRelays() -> [any UDPFlowRelaying] {
        lock.lock()
        defer { lock.unlock() }

        let relays = entries.values.map(\.relay)
        entries.removeAll()
        return relays
    }

    /// 调用方须持锁
    private func evictExpired() -> [any UDPFlowRelaying] {
        let cutoff = now().addingTimeInterval(-idleTimeout)
        let expiredKeys = entries.filter { $0.value.lastActiveAt < cutoff }.map(\.key)
        return expiredKeys.compactMap { entries.removeValue(forKey: $0)?.relay }
    }

    /// 调用方须持锁；超容量时淘汰最久未活跃的会话
    private func evictOverflow() -> [any UDPFlowRelaying] {
        guard entries.count > capacity, let oldest = entries.min(by: {
            $0.value.lastActiveAt < $1.value.lastActiveAt
        }) else {
            return []
        }

        return [entries.removeValue(forKey: oldest.key)?.relay].compactMap { $0 }
    }
}
