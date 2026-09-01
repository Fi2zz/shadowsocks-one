import Foundation

/// 调试开关统一读取：模拟器走启动参数（UserDefaults 参数域，
/// `-SSBrowserOpenURL ...`）；真机 devicectl 拒绝 `-` 前缀参数，
/// 走 `DEVICECTL_CHILD_` 环境变量透传（`DEVICECTL_CHILD_SSBrowserOpenURL=...`）
enum BrowserDebugFlags {
    static func value(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
            ?? ProcessInfo.processInfo.environment[key]
    }
}
