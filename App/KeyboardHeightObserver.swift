import SwiftUI
import UIKit

/// 跟踪键盘在屏幕上的可见高度。
///
/// 系统键盘安全区对第三方键盘（微信键盘等）不生效（iOS 26.6 实测），
/// safeAreaInset 与系统自动避让都会失效；键盘通知的 endFrame 实测可靠，
/// 因此底栏避让高度由本类手动计算，布局侧需同时忽略 .keyboard 安全区，
/// 避免系统键盘下与系统避让叠加。
final class KeyboardHeightObserver: ObservableObject {
    @Published private(set) var height: CGFloat = 0
    @Published private(set) var animation: Animation = .easeOut(duration: 0.25)

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleFrameChange(_ note: Notification) {
        guard let userInfo = note.userInfo else { return }
        height = visibleHeight(from: userInfo)
        animation = .easeOut(duration: animationDuration(from: userInfo))
    }

    /// endFrame 为屏幕坐标；键盘收起时 minY 落到屏幕底边，高度自然归 0
    private func visibleHeight(from userInfo: [AnyHashable: Any]) -> CGFloat {
        guard let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return 0
        }
        return max(0, screenBounds().maxY - endFrame.minY)
    }

    private func screenBounds() -> CGRect {
        keyWindow()?.screen.bounds ?? UIScreen.main.bounds
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }

    private func animationDuration(from userInfo: [AnyHashable: Any]) -> Double {
        userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
    }
}
