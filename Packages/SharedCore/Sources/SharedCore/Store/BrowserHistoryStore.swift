import Foundation

public final class BrowserHistoryStore {
    public static let maxEntryCount = 200

    private let jsonURL: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        self.jsonURL = directory.appendingPathComponent("browser-history.json")
    }

    init(jsonURL: URL) {
        self.jsonURL = jsonURL
    }

    public func loadEntries() throws -> [BrowserHistoryEntry] {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            return []
        }

        let data = try Data(contentsOf: jsonURL)
        return try JSONDecoder().decode([BrowserHistoryEntry].self, from: data)
    }

    public func append(_ entry: BrowserHistoryEntry) throws {
        var entries = try loadEntries()
        entries.removeAll { $0.url == entry.url }
        entries.insert(entry, at: 0)
        try save(Array(entries.prefix(Self.maxEntryCount)))
    }

    public func clear() throws {
        try save([])
    }

    private func save(_ entries: [BrowserHistoryEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: jsonURL, options: .atomic)
    }
}
