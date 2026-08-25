import Foundation

/// 多标签持久化：目录下 tabs.json 存标签数组，states/{id}.bin 存
/// WKWebView.interactionState（含前进后退栈），snapshots/{id}.jpg 存切换器缩略图。
public final class BrowserTabStore {
    public let directory: URL

    private let defaults: UserDefaults
    private var tabsFile: URL { directory.appendingPathComponent("tabs.json") }

    /// - Parameters:
    ///   - directory: 传入 Application Support/<App>/Tabs 一类的专属目录
    ///   - defaults: 存 activeTabID 的 UserDefaults，默认 standard；测试注入独立 suite
    public init(
        directory: URL,
        defaults: UserDefaults = .standard
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        for subdirectory in ["states", "snapshots"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(subdirectory, isDirectory: true),
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        self.directory = directory
        self.defaults = defaults
    }

    public func loadTabs() -> [BrowserTab] {
        guard let data = try? Data(contentsOf: tabsFile),
              let tabs = try? JSONDecoder().decode([BrowserTab].self, from: data)
        else { return [] }
        return tabs
    }

    public func save(_ tabs: [BrowserTab], activeID: UUID?) throws {
        let data = try JSONEncoder().encode(tabs)
        try data.write(to: tabsFile, options: .atomic)
        defaults.set(activeID?.uuidString, forKey: Self.activeIDKey)
    }

    public func loadActiveID() -> UUID? {
        defaults.string(forKey: Self.activeIDKey).flatMap(UUID.init)
    }

    public func saveState(_ data: Data?, for tab: BrowserTab) {
        let url = stateURL(for: tab)
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func loadState(for tab: BrowserTab) -> Data? {
        try? Data(contentsOf: stateURL(for: tab))
    }

    public func snapshotURL(for tab: BrowserTab) -> URL {
        directory.appendingPathComponent("snapshots/\(tab.id.uuidString).jpg")
    }

    public func deleteFiles(for tab: BrowserTab) {
        try? FileManager.default.removeItem(at: stateURL(for: tab))
        try? FileManager.default.removeItem(at: snapshotURL(for: tab))
    }

    private func stateURL(for tab: BrowserTab) -> URL {
        directory.appendingPathComponent("states/\(tab.id.uuidString).bin")
    }

    private static let activeIDKey = "browserActiveTabID"
}
