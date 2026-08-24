import Foundation

/// user_info 中仅用于展示的账号摘要。
struct HudunAccountSummary: Equatable {
    let uid: String
    let phone: String
    let expireText: String
    let vipExpireText: String
    let deviceText: String

    static func parse(_ dict: [String: Any]) -> HudunAccountSummary {
        HudunAccountSummary(
            uid: flexString(dict, ["uid"]),
            phone: flexString(dict, ["phone", "username"]),
            expireText: epochText(dict, ["expire_time"]),
            vipExpireText: epochText(dict, ["vip_expire_time"]),
            deviceText: deviceCount(dict))
    }

    private static func flexibleValue(_ key: String, in dict: [String: Any]) -> String? {
        switch dict[key] {
        case let text as String:
            return text.isEmpty ? nil : text
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func flexString(_ dict: [String: Any], _ keys: [String]) -> String {
        let value = keys.lazy.compactMap { flexibleValue($0, in: dict) }.first
        return value ?? "—"
    }

    private static func epochText(_ dict: [String: Any], _ keys: [String]) -> String {
        let raw = keys.lazy.compactMap { flexibleValue($0, in: dict) }.first ?? ""
        guard let seconds = Double(raw), seconds > 0 else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static func deviceCount(_ dict: [String: Any]) -> String {
        let used = Double(flexibleValue("use_device_num", in: dict) ?? "") ?? 0
        let online = Double(flexibleValue("online_device_num", in: dict) ?? "") ?? 0
        guard used > 0 || online > 0 else { return "—" }
        return "已用 \(Int(used)) · 在线 \(Int(online))"
    }
}
