import Foundation

/// 页面顶色探测结果，驱动 Safari 式状态栏染色。
/// JS 探针上报 "r,g,b,a"（0-255/0-1）或 "none"，本类型负责解析、
/// 与底色合成、以及按线性亮度判定状态栏文字深浅。
public struct BrowserPageTint: Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 解析探针消息；"none" 或格式非法返回 nil（调用方回退系统底色）
    public init?(message: String?) {
        guard let message, message != BrowserTintProbeMessage.none else { return nil }
        let parts = message.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        red = parts[0]
        green = parts[1]
        blue = parts[2]
        alpha = parts[3]
    }

    /// 半透明顶色（玻璃头部）按底色合成，结果不透明
    public func resolved(over background: BrowserPageTint) -> BrowserPageTint {
        guard alpha < 1 else { return self }
        let weight = alpha
        return BrowserPageTint(
            red: red * weight + background.red * (1 - weight),
            green: green * weight + background.green * (1 - weight),
            blue: blue * weight + background.blue * (1 - weight),
            alpha: 1
        )
    }

    /// WCAG 线性亮度 < 0.5 视为深色顶色，状态栏文字应改用浅色（对齐 Safari）
    public var prefersLightStatusBarText: Bool {
        luminance < 0.5
    }

    private var luminance: Double {
        0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    private func linearized(_ channel: Double) -> Double {
        let unit = min(max(channel / 255, 0), 1)
        return unit <= 0.04045 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
    }
}

public enum BrowserTintProbeMessage {
    public static let none = "none"
}
