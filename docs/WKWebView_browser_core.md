# WKWebView 浏览器核心功能实现方案（SwiftUI 版）

> 本文档是一份完整的实现规格说明，供 AI 模型或开发者直接据此编码，无需额外上下文。
> 技术栈：Swift / SwiftUI / WKWebView（UIViewRepresentable 桥接），最低部署版本 iOS 15。

---

## 1. 项目背景与现状

正在开发一个基于 WKWebView 的 iOS 浏览器 App（使用系统内核，不自研渲染引擎），UI 层全面使用 **SwiftUI**。

**已完成（不要重做）：**
- 地址栏：URL 与搜索词识别、输入跳转
- 前进 / 后退 / 刷新
- 历史记录：已有持久化存储（假设存在 `HistoryStore.shared.add(url:title:)` 接口，实际接代码时对齐现有方法签名）

**本次要实现：多 Tab 为核心的最小完整浏览器。**

---

## 2. 功能范围

### 做（本次范围）

| 模块 | 内容 |
|---|---|
| 多 Tab | 新建 / 关闭 / 切换、Safari 式层叠卡片切换器、关闭 App 后恢复上次标签 |
| 后台打开 | `target="_blank"` / `window.open` 链接在后台新建标签，不打断当前浏览，Toast 提示带「查看」跳转 |
| 已有功能接入 | 地址栏、前进后退、历史记录挂到 Tab 模型上（每个 Tab 独立的前进后退栈） |
| 书签 | 添加 / 删除 / 列表页，复用历史记录的存储层 |
| 健壮性 | 新窗口链接接住、外部 scheme 跳转、WebContent 进程终止自动恢复 |
| 隐私 | 一键清除网站数据 + 历史记录 |

### 不做（明确排除，避免范围蔓延）

无痕模式、下载管理、广告拦截、账号同步、阅读模式、iPad 多窗口。架构上已为这些预留扩展空间，未来加入时不需要重构 Tab 层。

---

## 3. 已确认的交互决策

1. **标签切换器 = Safari 风格**：全屏界面，卡片纵向堆叠、带 3D 透视倾斜、上部重叠，上下滚动浏览，**左滑关闭**，点按选中，底部工具条左侧 `＋`、右侧「完成」，进入时自动滚动到当前标签
2. **新窗口链接 = 后台打开**：新建标签但不切换 `activeTabID`，标签数按钮弹跳反馈 + 底部 Toast「已在后台打开 [查看]」，3 秒自动消失
3. **后台标签懒加载**：后台创建的标签不立即创建 WebView，URL 存在数据层，用户切过去才真正加载（省内存）；不要做后台预加载
4. **WebView LRU 缓存**：内存中最多保活 4 个 WebView，淘汰前先把 `interactionState` 和缩略图落盘

---

## 4. 总体架构（SwiftUI）

```
TabManager: ObservableObject（单例，核心协调者，@MainActor）
├── @Published tabs: [BrowserTab]             // 全部标签（纯数据，驱动 SwiftUI）
├── @Published activeTabID: UUID?
├── webViewCache: [UUID: WKWebView]（私有）    // LRU，最多 4 个活的 WebView
├── webViewFactory: (() -> WKWebView)!        // 启动时注入，负责挂 delegate
└── TabStore（持久化，目录 = Application Support/Tabs/）
    ├── tabs.json                             // [BrowserTab] + UserDefaults 存 activeTabID
    ├── states/{tabID}.bin                    // interactionState（含前进后退栈）
    └── snapshots/{tabID}.jpg                 // 切换器缩略图

WebViewDelegate（单例，NSObject，所有 WebView 共用的 WKNavigationDelegate + WKUIDelegate）
└── 事件通过闭包转发给 BrowserViewModel（后台打开 Toast 等）

BrowserViewModel: ObservableObject（主界面状态）
├── @Published 地址栏文本 / 加载进度 / canGoBack / canGoForward / Toast 状态
└── 对当前激活 WebView 的 KVO 观察（NSKeyValueObservation 数组，切标签时整体替换）

SwiftUI 视图层
├── BrowserView（主界面）
│   ├── AddressBarView（已有，改造为绑定 BrowserViewModel）
│   ├── WebViewContainer（UIViewRepresentable，只负责"挂载"缓存的 WebView）
│   ├── 底部工具条：← → ｜＋｜ [标签数按钮] ｜ ⋯（书签/清除数据）
│   └── .fullScreenCover → TabSwitcherView（层叠卡片切换器）
└── TabSwitcherView = ScrollView + LazyVStack（负间距重叠）+ rotation3DEffect
```

**SwiftUI 版的核心原则：WKWebView 实例的生命周期由 TabManager 管理，绝不交给 SwiftUI 视图生命周期。** `UIViewRepresentable` 只做"把缓存中的 WebView 挂到容器视图上"这一件事——WebView 不会因为视图重建、fullScreenCover 弹出而被销毁重建，页面状态和前进后退栈因此得以保留。

**关键持久化决策：用 `WKWebView.interactionState`（iOS 15+）保存/恢复标签。** 这是唯一能连前进后退栈一起持久化的官方方式（`backForwardList` 只读，无法存取）。恢复时优先设置 `interactionState`；为空或失败才退化为加载 `tab.url`。

---

## 5. 数据模型与持久化（与 UI 框架无关）

```swift
import Foundation
import UIKit

struct BrowserTab: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var url: URL?
    var createdAt: Date
    var lastActiveAt: Date

    var snapshotPath: String { "snapshots/\(id.uuidString).jpg" }
    var statePath: String { "states/\(id.uuidString).bin" }
}

final class TabStore {
    let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Tabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("states"),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("snapshots"),
                                                 withIntermediateDirectories: true)
        return base
    }()

    private var tabsFile: URL { dir.appendingPathComponent("tabs.json") }

    func loadTabs() -> [BrowserTab] {
        guard let data = try? Data(contentsOf: tabsFile),
              let tabs = try? JSONDecoder().decode([BrowserTab].self, from: data)
        else { return [] }
        return tabs
    }

    func saveTabs(_ tabs: [BrowserTab], activeID: UUID?) {
        if let data = try? JSONEncoder().encode(tabs) {
            try? data.write(to: tabsFile, options: .atomic)
        }
        UserDefaults.standard.set(activeID?.uuidString, forKey: "activeTabID")
    }

    func loadActiveID() -> UUID? {
        (UserDefaults.standard.string(forKey: "activeTabID")).flatMap(UUID.init)
    }

    func saveState(_ data: Data?, for tab: BrowserTab) {
        let url = dir.appendingPathComponent(tab.statePath)
        if let data { try? data.write(to: url, options: .atomic) }
        else { try? FileManager.default.removeItem(at: url) }
    }

    func loadState(for tab: BrowserTab) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(tab.statePath))
    }

    func deleteFiles(for tab: BrowserTab) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(tab.statePath))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(tab.snapshotPath))
    }
}
```

---

## 6. TabManager（ObservableObject 版）

```swift
import WebKit
import UIKit

@MainActor
final class TabManager: ObservableObject {
    static let shared = TabManager()

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var activeTabID: UUID?

    private var webViewCache: [UUID: WKWebView] = [:]
    private let maxLiveWebViews = 4
    let store = TabStore()

    /// 启动时注入：创建 WebView 并挂代理（见第 7 节）
    var webViewFactory: (() -> WKWebView)!

    private init() { restore() }

    // MARK: - 生命周期

    private func restore() {
        tabs = store.loadTabs()
        activeTabID = store.loadActiveID()
        if tabs.isEmpty { _ = createTab() }
        if activeTabID == nil || !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.first?.id
        }
    }

    /// 在 App 的 scenePhase 变为 .background 时调用
    func persistAll() {
        for (id, webView) in webViewCache {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            store.saveState(webView.interactionState, for: tab)
            saveSnapshot(of: webView, for: tab)
        }
        store.saveTabs(tabs, activeID: activeTabID)
    }

    // MARK: - Tab 操作

    @discardableResult
    func createTab(url: URL? = nil, activate: Bool = true) -> BrowserTab {
        let tab = BrowserTab(id: UUID(), title: "新标签页", url: url,
                             createdAt: Date(), lastActiveAt: Date())
        tabs.append(tab)
        if activate { activeTabID = tab.id }
        return tab
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        webViewCache.removeValue(forKey: id)
        store.deleteFiles(for: tab)
        if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty { _ = createTab() }   // 永远保证至少一个标签
    }

    func selectTab(_ id: UUID) {
        guard activeTabID != id, tabs.contains(where: { $0.id == id }) else { return }
        // 离开当前标签前保存状态
        if let currentID = activeTabID,
           let webView = webViewCache[currentID],
           let current = tabs.first(where: { $0.id == currentID }) {
            store.saveState(webView.interactionState, for: current)
            saveSnapshot(of: webView, for: current)
        }
        activeTabID = id
        touch(id)
    }

    func updateTab(_ id: UUID, title: String? = nil, url: URL? = nil) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty { tabs[i].title = title }
        if let url { tabs[i].url = url }
    }

    // MARK: - WebView 供给（核心）

    func webView(for tabID: UUID) -> WKWebView {
        if let cached = webViewCache[tabID] { return cached }

        evictIfNeeded()
        let webView = webViewFactory()

        // 优先用 interactionState 完整恢复（页面 + 前进后退栈）
        if let tab = tabs.first(where: { $0.id == tabID }),
           let state = store.loadState(for: tab), !state.isEmpty {
            webView.interactionState = state
        } else if let url = tabs.first(where: { $0.id == tabID })?.url {
            webView.load(URLRequest(url: url))
        }

        webViewCache[tabID] = webView
        touch(tabID)
        return webView
    }

    var activeWebView: WKWebView? {
        guard let id = activeTabID else { return nil }
        return webView(for: id)
    }

    func tabID(for webView: WKWebView) -> UUID? {
        webViewCache.first(where: { $0.value === webView })?.key
    }

    func snapshotImage(for tab: BrowserTab) -> UIImage? {
        UIImage(contentsOfFile: store.dir.appendingPathComponent(tab.snapshotPath).path)
    }

    // MARK: - 内部

    private func touch(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].lastActiveAt = Date()
    }

    private func evictIfNeeded() {
        guard webViewCache.count >= maxLiveWebViews else { return }
        let victim = tabs
            .filter { webViewCache[$0.id] != nil && $0.id != activeTabID }
            .min(by: { $0.lastActiveAt < $1.lastActiveAt })
        if let victim, let webView = webViewCache.removeValue(forKey: victim.id) {
            store.saveState(webView.interactionState, for: victim)
            saveSnapshot(of: webView, for: victim)
        }
    }

    private func saveSnapshot(of webView: WKWebView, for tab: BrowserTab) {
        webView.takeSnapshot(with: nil) { [store] image, _ in
            guard let image, let data = image.jpegData(compressionQuality: 0.6) else { return }
            try? data.write(to: store.dir.appendingPathComponent(tab.snapshotPath))
        }
    }
}
```

---

## 7. WebView 桥接与代理

### 7.1 WebViewDelegate（所有 WebView 共用）

```swift
import WebKit

final class WebViewDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = WebViewDelegate()

    /// 后台打开了新标签（主界面注入，用于弹 Toast）
    var onBackgroundOpen: ((UUID) -> Void)?

    // ① 新窗口链接 → 后台打开（不接则 target="_blank" 链接点击无反应）
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else { return nil }
        let newTab = TabManager.shared.createTab(url: url, activate: false)
        Task { @MainActor in onBackgroundOpen?(newTab.id) }
        return nil
    }

    // ② 外部 scheme 跳转
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about"].contains(scheme) {
            UIApplication.shared.open(url)   // tel: / mailto: / itms-apps: / 第三方 App
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    // ③ WebContent 进程被系统杀掉（内存压力）：不处理就是白屏
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // ④ 页面加载完成：更新 Tab 元数据 + 写历史
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard let id = TabManager.shared.tabID(for: webView) else { return }
            TabManager.shared.updateTab(id, title: webView.title, url: webView.url)
            if let url = webView.url, url.scheme?.hasPrefix("http") == true {
                HistoryStore.shared.add(url: url, title: webView.title ?? "")  // 对齐现有接口
            }
        }
    }
}
```

### 7.2 工厂注入（App 启动时）

```swift
TabManager.shared.webViewFactory = {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.allowsBackForwardNavigationGestures = true   // 侧滑前进后退
    let delegate = WebViewDelegate.shared
    webView.navigationDelegate = delegate
    webView.uiDelegate = delegate
    return webView
}
```

### 7.3 WebViewContainer（UIViewRepresentable，只挂载不创建）

```swift
import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let tabID: UUID

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // tabID 变化时 SwiftUI 会自动调用本方法，在此切换挂接的 WebView
        let webView = TabManager.shared.webView(for: tabID)
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}
```

**注意：不要给 WebViewContainer 加 `.id(tabID)`**——那会销毁重建整个 representable。`tabID` 变化时 SwiftUI 会调用 `updateUIView`，在其中换 WebView 即可，容器视图本身复用。

---

## 8. 主界面（BrowserView + BrowserViewModel）

### 8.1 BrowserViewModel

```swift
import WebKit

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var addressText = ""
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var showSwitcher = false
    @Published var backgroundToastTabID: UUID?   // 非 nil 时显示 Toast

    private var observations: [NSKeyValueObservation] = []

    init() {
        WebViewDelegate.shared.onBackgroundOpen = { [weak self] id in
            self?.backgroundToastTabID = id
        }
        observeActiveWebView()
    }

    /// 激活标签变化时调用：整体替换 KVO 观察（旧 observation 随数组释放自动失效）
    func observeActiveWebView() {
        guard let webView = TabManager.shared.activeWebView else { return }
        addressText = webView.url?.absoluteString ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        progress = webView.estimatedProgress

        observations = [
            webView.observe(\.URL, options: .new) { [weak self] wv, _ in
                Task { @MainActor in self?.addressText = wv.url?.absoluteString ?? "" }
            },
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in
                Task { @MainActor in self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoForward = wv.canGoForward }
            },
        ]
    }

    // MARK: - 用户操作

    func load() {
        // 复用已有的"URL 还是搜索词"识别逻辑，产出最终 URL
        guard let url = AddressParser.parse(addressText) else { return }
        TabManager.shared.activeWebView?.load(URLRequest(url: url))
    }

    func goBack()    { TabManager.shared.activeWebView?.goBack() }
    func goForward() { TabManager.shared.activeWebView?.goForward() }
    func reload()    { TabManager.shared.activeWebView?.reload() }

    func viewBackgroundTab() {
        guard let id = backgroundToastTabID else { return }
        backgroundToastTabID = nil
        TabManager.shared.selectTab(id)
        observeActiveWebView()
    }
}
```

### 8.2 BrowserView

```swift
struct BrowserView: View {
    @StateObject private var vm = BrowserViewModel()
    @ObservedObject private var tabs = TabManager.shared

    var body: some View {
        VStack(spacing: 0) {
            AddressBarView(text: $vm.addressText, onSubmit: vm.load)   // 已有组件改造

            ZStack(alignment: .top) {
                if let id = tabs.activeTabID {
                    WebViewContainer(tabID: id)
                }
                ProgressView(value: vm.progress)
                    .opacity(vm.progress < 1 ? 1 : 0)
                    .animation(.easeOut, value: vm.progress)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomToolbar
        }
        .onChange(of: tabs.activeTabID) { _ in vm.observeActiveWebView() }
        .fullScreenCover(isPresented: $vm.showSwitcher) {
            TabSwitcherView()
        }
        .overlay(alignment: .bottom) { backgroundToast }
    }

    private var bottomToolbar: some View {
        HStack {
            Button(action: vm.goBack)    { Image(systemName: "chevron.left") }
                .disabled(!vm.canGoBack)
            Button(action: vm.goForward) { Image(systemName: "chevron.right") }
                .disabled(!vm.canGoForward)
            Spacer()
            Button { tabs.createTab(); vm.observeActiveWebView() } label: {
                Image(systemName: "plus")
            }
            Spacer()
            Button { vm.showSwitcher = true } label: {
                Text("\(tabs.tabs.count)")   // Safari 风格：圆角方框内显示标签数
                    .font(.footnote.bold())
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary, lineWidth: 2))
            }
            Spacer()
            Menu {   // ⋯：添加书签 / 书签列表 / 清除数据
                Button("添加书签") { /* 见第 11 节 */ }
                Button("书签列表") { /* 见第 11 节 */ }
                Button("清除浏览数据", role: .destructive) { clearBrowsingData() }
            } label: { Image(systemName: "ellipsis") }
        }
        .padding(.horizontal)
        .frame(height: 44)
    }

    private var backgroundToast: some View {
        Group {
            if vm.backgroundToastTabID != nil {
                HStack {
                    Text("已在后台打开")
                    Spacer()
                    Button("查看", action: vm.viewBackgroundTab)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 60)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { vm.backgroundToastTabID = nil }
                }
            }
        }
        .animation(.spring(), value: vm.backgroundToastTabID)
    }
}
```

---

## 9. Safari 式层叠卡片切换器（纯 SwiftUI）

### 9.1 卡片视图（含左滑关闭）

```swift
struct TabCardView: View {
    let tab: BrowserTab
    let width: CGFloat
    var onClose: () -> Void
    var onSelect: () -> Void

    @State private var offsetX: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tab.title).lineLimit(1).font(.subheadline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color(.secondarySystemBackground))

            Image(uiImage: TabManager.shared.snapshotImage(for: tab)
                  ?? UIImage(systemName: "globe")!)   // 后台未加载的标签无快照，显示占位图
                .resizable()
                .scaledToFill()
        }
        .frame(width: width, height: width * 0.72)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator), lineWidth: 0.5))
        .offset(x: offsetX)
        .opacity(1 - abs(offsetX) / width)
        .onTapGesture(perform: onSelect)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    let t = value.translation
                    // 只在明确横向（左）滑动时接管，避免与纵向滚动冲突
                    guard t.width < 0, abs(t.width) > abs(t.height) else { return }
                    offsetX = t.width
                }
                .onEnded { value in
                    if value.translation.width < -width * 0.35 {
                        withAnimation(.easeOut(duration: 0.2)) { offsetX = -width }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onClose() }
                    } else {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { offsetX = 0 }
                    }
                }
        )
    }
}
```

### 9.2 切换器（负间距重叠 + 滚动透视）

```swift
struct TabSwitcherView: View {
    @ObservedObject private var tabs = TabManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = proxy.size.width - 32
            let cardHeight = cardWidth * 0.72

            ZStack(alignment: .bottom) {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: -cardHeight * 0.72) {   // 负间距 → 上部重叠
                            ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                                GeometryReader { geo in
                                    let distance = (geo.frame(in: .global).midY
                                                    - proxy.size.height / 2) / proxy.size.height
                                    TabCardView(tab: tab, width: cardWidth,
                                                onClose: { tabs.closeTab(tab.id) },
                                                onSelect: { tabs.selectTab(tab.id); dismiss() })
                                        .rotation3DEffect(.degrees(distance * 13),
                                                          axis: (x: 1, y: 0, z: 0),
                                                          perspective: 0.9)   // Safari 纵深感
                                }
                                .frame(width: cardWidth, height: cardHeight)
                                .zIndex(Double(index))   // 后打开的标签盖在上面
                                .id(tab.id)
                            }
                        }
                        .padding(.top, 40)
                        .padding(.bottom, 120)
                    }
                    .onAppear {
                        if let id = tabs.activeTabID {
                            reader.scrollTo(id, anchor: .center)   // 第一眼看到当前标签
                        }
                    }
                }

                HStack {   // 底部工具条
                    Button { tabs.createTab(); dismiss() } label: { Image(systemName: "plus") }
                    Spacer()
                    Button("完成") { dismiss() }
                }
                .padding()
                .background(.bar)
            }
        }
        .background(Color(.systemBackground))
    }
}
```

**透视实现说明**：每张卡片内嵌 `GeometryReader` 读取其在屏幕上的位置，按与屏幕中心的距离施加 `rotation3DEffect`，滚动时 SwiftUI 自动逐帧更新——效果等价于 UIKit 版自定义 Layout 的 `CATransform3D` 透视，但不需要写 Layout 类。

---

## 10. 生命周期挂接（App 入口）

```swift
@main
struct BrowserApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 注入 WebView 工厂（见 7.2）
        TabManager.shared.webViewFactory = { /* ... */ }
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                TabManager.shared.persistAll()
            }
        }
    }
}
```

（若部署目标升到 iOS 17+，`onChange(of:)` 换成双参数新签名。）

---

## 11. 书签与数据清除（小模块）

**书签**：复用历史记录的存储层，新增 `bookmarks` 表（id / title / url / createdAt）。「添加书签」取当前 WebView 的 `title` + `url`；「书签列表」用 SwiftUI `List` + `swipeActions` 删除，点按在当前标签 `load`。

**清除数据**：同时清 WKWebView 数据和自有历史：

```swift
func clearBrowsingData() {
    WKWebsiteDataStore.default().removeData(
        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
        modifiedSince: .distantPast) { _ in }
    HistoryStore.shared.clearAll()   // 对齐现有接口
}
```

---

## 12. 实现顺序（每步可独立编译验证）

1. **BrowserTab + TabStore + TabManager**：不接 UI，先单测 create / close / select / persist / restore 闭环
2. **WebViewDelegate + webViewFactory + WebViewContainer**：单 WebView 能在 SwiftUI 里显示和导航
3. **BrowserViewModel + BrowserView**：地址栏 / 前进后退 / 进度条接到激活标签，KVO 随切换替换
4. **TabSwitcherView**：先跑通卡片列表与选中关闭，再调透视动画参数
5. **后台打开 + Toast**、**书签**、**清除数据**

预估核心代码量 600～800 行。第 1、2 步是关键路径：Tab 数据层和「WebView 归 TabManager 管、SwiftUI 只挂载」这条原则立住后，其余都是常规工作。

---

## 13. 边界情况与已知坑清单（含 SwiftUI 特有）

- [ ] **WebView 不能交给 SwiftUI 生命周期**：所有创建走 `webViewFactory` + `webViewCache`；`WebViewContainer` 不加 `.id()`，只在 `updateUIView` 里换挂接对象
- [ ] **KVO 随切换整体替换**：`observations` 数组重新赋值时旧观察自动失效，无需手动 remove；回调里 `weak self` + `Task { @MainActor }` 防循环引用和线程问题
- [ ] **关闭最后一个标签**：TabManager 自动补一个新标签，永远保证 ≥1 个（已在 `closeTab` 处理）
- [ ] **后台标签无缩略图**：从未加载的标签在切换器显示占位图（globe），属预期
- [ ] **interactionState 恢复失败**（极少见，如跨版本数据不兼容）：退化为加载 `tab.url`，前进后退栈丢失可接受
- [ ] **WebContent 进程被杀**：必须实现 `webViewWebContentProcessDidTerminate` → reload，否则用户切回标签看到白屏
- [ ] **fullScreenCover 不销毁底层视图**：切换器用 fullScreenCover 弹出期间 BrowserView 及其挂接的 WebView 保持存活，返回后无需恢复
- [ ] **LazyVStack + 负间距的命中测试**：重叠区域中上层卡片（zIndex 大）优先响应手势，与 Safari 一致；若出现点按穿透检查 `zIndex` 是否正确设置
- [ ] **历史记录去重与容量**：同一 URL 短时间重复访问去重；建议上限 3 万条 + 定期清理 90 天前数据，早加索引
- [ ] **快照时机**：进后台、切走、LRU 淘汰三处都存快照；空白/错误页的快照也是空白，属预期

---

## 14. 验收标准

1. 开 10 个标签浏览不同网站，强杀 App 重开：标签列表、每个标签的页面和前进后退栈全部恢复
2. `target="_blank"` 链接：后台新建标签，当前页不跳动，Toast 3 秒消失，点「查看」跳转
3. 切换器：卡片透视堆叠滚动流畅，左滑关闭有回弹/飞出动画，点按选中回到主界面且 WebView 状态正确（进度、滚动位置、前进后退栈都在）
4. 连续开 20 个标签内存不爆（LRU 生效，最多 4 个活 WebView）
5. 内存警告后切回任一标签不白屏（自动 reload）
6. `tel:`、`mailto:`、App Store 链接正确跳转到系统 App
7. 打开切换器再返回，当前页面的 WebView 没有被重建（页面不重载、滚动位置不变）
