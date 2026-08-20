import Foundation

public final class TunnelRuntimeStatusStore: @unchecked Sendable {
    private enum Keys {
        static let lastFailureDetail = "packetTunnel.lastFailureDetail"
    }

    private let userDefaults: UserDefaults

    public init(appGroupID: String) throws {
        guard let userDefaults = UserDefaults(suiteName: appGroupID) else {
            throw CocoaError(.fileNoSuchFile)
        }

        self.userDefaults = userDefaults
    }

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    public func saveLastFailureDetail(_ detail: String) {
        let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDetail.isEmpty else {
            clearLastFailureDetail()
            return
        }

        userDefaults.set(normalizedDetail, forKey: Keys.lastFailureDetail)
    }

    @discardableResult
    public func consumeLastFailureDetail() -> String? {
        let detail = userDefaults.string(forKey: Keys.lastFailureDetail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        userDefaults.removeObject(forKey: Keys.lastFailureDetail)

        guard let detail, !detail.isEmpty else {
            return nil
        }

        return detail
    }

    public func clearLastFailureDetail() {
        userDefaults.removeObject(forKey: Keys.lastFailureDetail)
    }
}
