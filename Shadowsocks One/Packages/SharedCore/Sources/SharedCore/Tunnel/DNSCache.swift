import Foundation

public final class DNSCache: @unchecked Sendable {
    private struct Entry: Sendable {
        let addresses: Set<String>
        let expiresAt: Date
    }

    private let now: () -> Date
    private var storage: [String: Entry] = [:]
    private let lock = NSLock()

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func insert(
        domain: String,
        addresses: [String],
        ttl: TimeInterval
    ) {
        let normalizedDomain = Self.normalize(domain)
        guard !normalizedDomain.isEmpty, !addresses.isEmpty else {
            return
        }

        let entry = Entry(
            addresses: Set(addresses),
            expiresAt: now().addingTimeInterval(max(ttl, 0))
        )

        lock.lock()
        storage[normalizedDomain] = entry
        lock.unlock()
    }

    public func contains(domain: String, address: String) -> Bool {
        let normalizedDomain = Self.normalize(domain)
        guard !normalizedDomain.isEmpty else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        guard let entry = storage[normalizedDomain] else {
            return false
        }

        guard entry.expiresAt > now() else {
            storage.removeValue(forKey: normalizedDomain)
            return false
        }

        return entry.addresses.contains(address)
    }

    private static func normalize(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}
