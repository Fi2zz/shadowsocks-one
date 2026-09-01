import SwiftUI
import UIKit

/// SwiftUI 没有按视图控制状态栏文字样式与 Home 指示条显隐的 API；
/// 借宿生的空 VC 承接 preferredStatusBarStyle（深色顶色时切浅色文字）
/// 与 prefersHomeIndicatorAutoHidden（自动隐藏底部小横条），对齐 Safari。
struct BrowserStatusBarGate: UIViewControllerRepresentable {
    let prefersLightText: Bool

    func makeUIViewController(context: Context) -> GateViewController {
        GateViewController()
    }

    func updateUIViewController(_ controller: GateViewController, context: Context) {
        controller.prefersLightText = prefersLightText
    }

    final class GateViewController: UIViewController {
        var prefersLightText = false {
            didSet {
                guard oldValue != prefersLightText else { return }
                setNeedsStatusBarAppearanceUpdate()
            }
        }

        override var preferredStatusBarStyle: UIStatusBarStyle {
            prefersLightText ? .lightContent : .default
        }

        override var prefersHomeIndicatorAutoHidden: Bool { true }
    }
}
