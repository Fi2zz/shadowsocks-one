import Combine
import SharedCore
import WebKit

/// 多标签核心协调者。标签是纯数据（驱动 SwiftUI），WebView 实例归本类的
/// LRU 缓存所有（内存最多保活 maxLiveWebViews 个，淘汰前落盘状态与缩略图），
/// SwiftUI 只挂载；标签与页面会话经 interactionState 持久化，重启可恢复。
@MainActor
final class BrowserTabManager: ObservableObject {
    static let shared = makeDefault()

    // setter 供 +Persistence / +Library 扩展刷新（同模块内），外部只读
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabID: UUID?
    @Published var history: [BrowserHistoryEntry] = []
    @Published var bookmarks: [BrowserBookmarkEntry] = []

    let store: BrowserTabStore?
    let historyStore: BrowserHistoryStore?
    let bookmarkStore: BrowserBookmarkStore?

    private let webViewFactory: () -> WKWebView
    var webViewCache: [UUID: WKWebView] = [:]
    let maxLiveWebViews = 4

    init(
        store: BrowserTabStore?,
        historyStore: BrowserHistoryStore?,
        bookmarkStore: BrowserBookmarkStore?,
        factory: @escaping () -> WKWebView
    ) {
        self.store = store
        self.historyStore = historyStore
        self.bookmarkStore = bookmarkStore
        self.webViewFactory = factory
        restoreTabs()
        reloadHistory()
        reloadBookmarks()
    }

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == activeTabID }
    }

    // MARK: - 标签操作

    @discardableResult
    func createTab(url: URL? = nil, activate: Bool = true) -> BrowserTab {
        let tab = BrowserTab(title: "新标签页", url: url)
        tabs.append(tab)
        if activate {
            activeTabID = tab.id
        }
        return tab
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let tab = tabs.remove(at: index)
        webViewCache.removeValue(forKey: id)
        store?.deleteFiles(for: tab)
        if activeTabID == id {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty {
            createTab()
        }
    }

    /// 切换前把离开标签的 interactionState 与缩略图落盘
    func selectTab(_ id: UUID) {
        guard activeTabID != id, tabs.contains(where: { $0.id == id }) else {
            return
        }
        persistSession(of: activeTabID)
        activeTabID = id
        touch(id)
    }

    func open(_ url: URL) {
        activeWebView?.load(URLRequest(url: url))
    }

    func updateTab(_ id: UUID, title: String?, url: URL?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let title, !title.isEmpty {
            tabs[index].title = title
        }
        if let url {
            tabs[index].url = url
        }
    }

    // MARK: - WebView 供给

    func webView(for tabID: UUID) -> WKWebView {
        if let cached = webViewCache[tabID] {
            return cached
        }
        evictIfNeeded()
        let webView = webViewFactory()
        restoreSession(into: webView, tabID: tabID)
        webViewCache[tabID] = webView
        // 不在此处 touch（lastActiveAt 已由 create/select 盖章），
        // 避免容器挂载期间变更 @Published 触发 SwiftUI 更新告警
        return webView
    }

    var activeWebView: WKWebView? {
        activeTabID.map { webView(for: $0) }
    }

    func tabID(for webView: WKWebView) -> UUID? {
        webViewCache.first(where: { $0.value === webView })?.key
    }

    func snapshotImage(for tab: BrowserTab) -> UIImage? {
        store.flatMap { UIImage(contentsOfFile: $0.snapshotURL(for: tab).path) }
    }

    // MARK: - 导航事件（共用代理回调）

    func handleDidFinish(_ webView: WKWebView) {
        guard let id = tabID(for: webView) else {
            return
        }
        updateTab(id, title: webView.title, url: webView.url)
        if let url = webView.url, url.scheme?.hasPrefix("http") == true {
            recordHistory(url: url, title: webView.title ?? "")
        }
    }

    static func makeDefault() -> BrowserTabManager {
        let base = applicationSupport.appendingPathComponent("ShadowsocksOne", isDirectory: true)
        return BrowserTabManager(
            store: try? BrowserTabStore(directory: base.appendingPathComponent("Tabs")),
            historyStore: try? BrowserHistoryStore(directory: base),
            bookmarkStore: try? BrowserBookmarkStore(directory: base),
            factory: BrowserWebViewFactory.make
        )
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}
