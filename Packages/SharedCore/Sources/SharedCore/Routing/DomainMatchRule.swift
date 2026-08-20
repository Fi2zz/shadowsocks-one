import Foundation

struct DomainMatchRule: Sendable, Equatable {
    private let pattern: String

    init(rawValue: String) {
        self.pattern = Self.normalize(rawValue)
    }

    func matches(_ host: String) -> Bool {
        let normalizedHost = Self.normalize(host)
        guard !pattern.isEmpty, !normalizedHost.isEmpty else {
            return false
        }

        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            guard !suffix.isEmpty, normalizedHost.count > suffix.count else {
                return false
            }

            return normalizedHost.hasSuffix(".\(suffix)")
        }

        return normalizedHost == pattern
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}
