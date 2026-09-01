import SwiftUI

extension View {
    /// 底部 chrome 胶囊材质：iOS 26 用 clear 玻璃 + 70% systemBackground 薄纱——
    /// 保留玻璃的边缘折射与质感，不带 regular 玻璃的奶白底色和投影（design.md §7），
    /// 同时避免全透玻璃与流过的网页内容糊在一起（tint 颜色随深浅色自适应）；
    /// 低版本回退超薄材质（半透明、无阴影），不用纯色——纯色实底会杀死穿透效果
    @ViewBuilder
    func liquidGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.clear.tint(glassVeilColor), in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var glassVeilColor: Color {
        Color(uiColor: .systemBackground).opacity(0.7)
    }
}
