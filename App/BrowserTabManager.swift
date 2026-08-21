import Foundation
import SharedCore

@MainActor
final class BrowserTabManager: ObservableObject {
    @Published private(set) var tabs: [WebViewStore] = []
    @Published private(set) var selectedTabID: UUID
    @Published private(set) var history: [BrowserHistoryEntry] = []

    private let historyStore: BrowserHistoryStore?

    init(historyStore: BrowserHistoryStore?) {
        self.historyStore = historyStore
        let firstTab = WebViewStore()
        self.tabs = [firstTab]
        self.selectedTabID = firstTab.id
        wireHistoryRecording(to: firstTab)
        reloadHistory()
    }

    static func makeDefault() -> BrowserTabManager {
        BrowserTabManager(historyStore: makeHistoryStore())
    }

    var selectedTab: WebViewStore? {
        tabs.first { $0.id == selectedTabID }
    }

    func addTab() {
        let tab = WebViewStore()
        wireHistoryRecording(to: tab)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        tabs.remove(at: index)
        ensureSelection(afterClosingAt: index)
    }

    func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else {
            return
        }
        selectedTabID = id
    }

    func open(_ url: URL) {
        selectedTab?.load(url)
    }

    func clearHistory() {
        try? historyStore?.clear()
        reloadHistory()
    }

    private func ensureSelection(afterClosingAt index: Int) {
        if tabs.isEmpty {
            addTab()
            return
        }
        guard !tabs.contains(where: { $0.id == selectedTabID }) else {
            return
        }
        selectedTabID = tabs[min(index, tabs.count - 1)].id
    }

    private func wireHistoryRecording(to tab: WebViewStore) {
        tab.onFinishNavigation = { [weak self] url, title in
            self?.recordHistory(url: url, title: title)
        }
    }

    private func recordHistory(url: URL, title: String) {
        try? historyStore?.append(BrowserHistoryEntry(url: url, title: title))
        reloadHistory()
    }

    private func reloadHistory() {
        history = (try? historyStore?.loadEntries()) ?? []
    }

    private static func makeHistoryStore() -> BrowserHistoryStore? {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = baseURL.appendingPathComponent("ShadowsocksOne", isDirectory: true)
        return try? BrowserHistoryStore(directory: directory)
    }
}
