import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// deviceid 生成规则（docs/hudun_master_doc.md §5.4）：
/// identifierForVendor 双拼，不可用时回退本地文件持久 UUID。
/// 语义 = 安装后稳定且与 token 配对。
enum HudunDeviceIdentity {
    static var stableID: String {
        #if canImport(UIKit)
        if let vendor = UIDevice.current.identifierForVendor?.uuidString.lowercased() {
            return vendor + vendor
        }
        #endif
        return fileBackedUUID()
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hudun_deviceid.txt")
    }

    private static func fileBackedUUID() -> String {
        if let saved = try? String(contentsOf: fileURL, encoding: .utf8), !saved.isEmpty {
            return saved
        }
        let fresh = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
        try? fresh.write(to: fileURL, atomically: true, encoding: .utf8)
        return fresh
    }
}
