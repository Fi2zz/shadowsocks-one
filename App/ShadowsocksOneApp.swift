import SwiftUI

@main
struct ShadowsocksOneApp: App {
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

    /// UI 自动化钩子：`simctl launch booted com.fits.socks.one -SSOneAutoOpen <url>`
    /// 启动参数会进入 UserDefaults 参数域，正常使用永远不会设置该键
    private static func openAutomationURLIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: "SSOneAutoOpen"),
              let url = URL(string: raw)
        else { return }
        DispatchQueue.main.async {
            BrowserTabManager.shared.open(url)
        }
    }
}
