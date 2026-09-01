import SwiftUI

extension View {
    /// 底部 chrome 胶囊材质：超薄材质 + 50% systemBackground 薄纱。
    /// 不用 iOS 26 liquid glass：glassEffect 对 WKWebView 进程外渲染的内容采样，
    /// 页面一滚动（WebKit 图层树更替）采样即失效，整组玻璃被永久压平成透明
    /// （2026-09-01 模拟器对照：仅加载存活、滚动后必现，tint/衬底/去重叠均无解）；
    /// 材质是进程内模糊，滚动后稳定存活。enabled=false 用于折叠动画不可见占位树
    @ViewBuilder
    func liquidGlassCapsule(enabled: Bool = true) -> some View {
        if !enabled {
            self
        } else {
            background(glassVeilColor, in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var glassVeilColor: Color {
        Color(uiColor: .systemBackground).opacity(0.5)
    }
}
