import SharedCore
import WebKit

// MARK: - 书签 / 历史 / 清除浏览数据
extension BrowserTabManager {
    var canBookmarkActivePage: Bool {
        selectedTab?.url != nil
    }

    /// 「添加书签」取当前页 title + url；同 URL 重复添加时覆盖标题
    func addBookmarkForActivePage() {
        guard let tab = selectedTab, let url = tab.url else {
            return
        }
        try? bookmarkStore?.append(BrowserBookmarkEntry(url: url, title: tab.title))
        reloadBookmarks()
    }

    func removeBookmark(id: UUID) {
        try? bookmarkStore?.remove(id: id)
        reloadBookmarks()
    }

    /// 一键清除：WKWebView 网站数据（Cookie/缓存/存储）+ 自有历史记录
    func clearBrowsingData() {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
        clearHistory()
    }

    func clearHistory() {
        try? historyStore?.clear()
        reloadHistory()
    }

    func recordHistory(url: URL, title: String) {
        try? historyStore?.append(BrowserHistoryEntry(url: url, title: title))
        reloadHistory()
    }

    func reloadHistory() {
        history = (try? historyStore?.loadEntries()) ?? []
    }

    func reloadBookmarks() {
        bookmarks = (try? bookmarkStore?.loadEntries()) ?? []
    }
}
