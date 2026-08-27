import SwiftUI

@main
struct ShadowsocksBrowserApp: App {
    private var runningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        Self.openAutomationURLIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            if runningTests {
                Text("Running Tests")
            } else {
                RootView()
            }
        }
    }

    /// UI 自动化钩子：`simctl launch booted com.fits.socks.browser -SSBrowserAutoOpen <url>`
    /// 启动参数会进入 UserDefaults 参数域，正常使用永远不会设置该键；
    /// `-SSBrowserAutoScroll <y>` 在页面加载后 6 秒滚动到指定位置（模拟器验证染色用）
    private static func openAutomationURLIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: "SSBrowserAutoOpen"),
              let url = URL(string: raw)
        else { return }
        DispatchQueue.main.async {
            let webView = BrowserTabManager.shared.activeWebView
            webView?.load(URLRequest(url: url))
            guard let scrollRaw = UserDefaults.standard.string(forKey: "SSBrowserAutoScroll"),
                  let scrollY = Double(scrollRaw)
            else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                webView?.evaluateJavaScript("window.scrollTo(0, \(scrollY))")
            }
        }
    }
}
