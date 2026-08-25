import Foundation

/// 书签存储：复用历史的 JSON 存储层形态，同 URL 重复添加时以新标题覆盖。
public final class BrowserBookmarkStore {
    private let jsonURL: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        self.jsonURL = directory.appendingPathComponent("browser-bookmarks.json")
    }

    init(jsonURL: URL) {
        self.jsonURL = jsonURL
    }

    public func loadEntries() throws -> [BrowserBookmarkEntry] {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            return []
        }
        let data = try Data(contentsOf: jsonURL)
        return try JSONDecoder().decode([BrowserBookmarkEntry].self, from: data)
    }

    /// 同 URL 已存在时更新其标题并保持原位置，否则插到最前。
    public func append(_ entry: BrowserBookmarkEntry) throws {
        var entries = try loadEntries()
        if let index = entries.firstIndex(where: { $0.url == entry.url }) {
            entries[index] = BrowserBookmarkEntry(
                id: entries[index].id,
                url: entry.url,
                title: entry.title,
                createdAt: entries[index].createdAt
            )
        } else {
            entries.insert(entry, at: 0)
        }
        try save(entries)
    }

    public func remove(id: UUID) throws {
        var entries = try loadEntries()
        entries.removeAll { $0.id == id }
        try save(entries)
    }

    private func save(_ entries: [BrowserBookmarkEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: jsonURL, options: .atomic)
    }
}
