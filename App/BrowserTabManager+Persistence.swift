import SharedCore
import WebKit

// MARK: - 会话持久化与 LRU 淘汰
extension BrowserTabManager {
    /// App 进后台时调用：全部缓存会话落盘 + 标签数组写盘
    func persistAll() {
        for (id, webView) in webViewCache {
            persistSession(of: id, webView: webView)
        }
        try? store?.save(tabs, activeID: activeTabID)
    }

    /// 启动恢复：读标签数组与 activeTabID，保证永远至少一个标签
    func restoreTabs() {
        tabs = store?.loadTabs() ?? []
        activeTabID = store?.loadActiveID()
        if tabs.isEmpty {
            createTab()
        }
        if activeTabID == nil || !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.first?.id
        }
    }

    func persistSession(of id: UUID?, webView: WKWebView? = nil) {
        guard let id,
              let cached = webView ?? webViewCache[id],
              let tab = tabs.first(where: { $0.id == id })
        else { return }
        // interactionState 是唯一能连前进后退栈一起持久化的官方方式
        store?.saveState(cached.interactionState as? Data, for: tab)
        saveSnapshot(of: cached, for: tab)
    }

    /// 优先用 interactionState 完整恢复（页面 + 前进后退栈）；
    /// 为空或失败才退化为加载 tab.url（前进后退栈丢失可接受）
    func restoreSession(into webView: WKWebView, tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return
        }
        if let state = store?.loadState(for: tab), !state.isEmpty {
            webView.interactionState = state
        } else if let url = tab.url {
            webView.load(URLRequest(url: url))
        }
    }

    /// 内存最多保活 maxLiveWebViews 个 WebView，淘汰最久未激活的非当前标签，
    /// 淘汰前先把 interactionState 和缩略图落盘
    func evictIfNeeded() {
        guard webViewCache.count >= maxLiveWebViews else {
            return
        }
        let candidates = tabs.filter { webViewCache[$0.id] != nil && $0.id != activeTabID }
        guard let victim = candidates.min(by: { $0.lastActiveAt < $1.lastActiveAt }),
              let webView = webViewCache.removeValue(forKey: victim.id)
        else { return }
        store?.saveState(webView.interactionState as? Data, for: victim)
        saveSnapshot(of: webView, for: victim)
    }

    func saveSnapshot(of webView: WKWebView, for tab: BrowserTab) {
        guard let store else {
            return
        }
        webView.takeSnapshot(with: nil) { image, _ in
            guard let image, let data = image.jpegData(compressionQuality: 0.6) else {
                return
            }
            try? data.write(to: store.snapshotURL(for: tab))
        }
    }

    func touch(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        tabs[index].lastActiveAt = Date()
    }
}
