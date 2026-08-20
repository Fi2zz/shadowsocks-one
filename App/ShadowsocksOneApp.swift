import SwiftUI

@main
struct ShadowsocksOneApp: App {
    private var runningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
}
