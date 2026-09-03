import SwiftUI

extension View {
    /// 底部 chrome 胶囊材质：iOS 26+ 用 clear 玻璃（折射质感）+ 60%
    /// systemBackground tint 控制玻璃强度（50% 起步、真机反馈加浓到 60%）；
    /// 低版本回退 ultraThinMaterial。
    /// 玻璃对 WKWebView 进程外渲染内容采样，2026-09-01 在 iOS 26.0 时代模拟器
    /// 曾复现"页面一滚动整组玻璃永久压平成透明"（对照实验锁定滚动为触发条件，
    /// tint/衬底/去重叠三路补救均无效）；2026-09-03 在 26.5 模拟器复测滚动与
    /// 折叠-展开循环均不复现，玻璃存活，故恢复 live glass。enabled=false 用于
    /// 折叠动画不可见占位树
    @ViewBuilder
    func liquidGlassCapsule(enabled: Bool = true) -> some View {
        if !enabled {
            self
        } else {
            // iOS 26+ 走真玻璃（clear 折射质感 + 50% tint 控制强度）；
            // 低版本无 Glass API，回退超薄材质
            if #available(iOS 26.0, *) {
                glassEffect(.clear.tint(glassVeilColor), in: Capsule())
            } else {
                background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var glassVeilColor: Color {
        Color(uiColor: .systemBackground).opacity(0.6)
    }
}
