import Foundation

public final class CNIPListStore {
    private let fileURL: URL

    public init(appGroupID: String) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        self.fileURL = containerURL.appendingPathComponent("cn-ip-list.txt")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    public func save(_ content: String) throws {
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
