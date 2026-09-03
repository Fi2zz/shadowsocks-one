import SwiftUI
import UIKit

/// Safari 式地址栏横拖切标签：按住地址栏再横向拖动，松手时按位移
/// 方向切换（向左 = 下一个、向右 = 上一个，跨标签循环）。
/// 用长按序列接管拖动，避免与 TextField 聚焦、文本选择手势冲突；
/// 展开/收起两种 chrome 形变态都挂同一修饰符。
struct AddressBarTabDrag: ViewModifier {
    /// 切换方向：+1 下一个、-1 上一个
    let onSwitch: (Int) -> Void

    func body(content: Content) -> some View {
        content.gesture(switchDrag)
    }

    private var switchDrag: some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 10))
            .onEnded { finish(with: $0) }
    }

    /// 横向位移超过阈值才切换，纵向拖动与短拖不触发
    private func finish(
        with value: SequenceGesture<LongPressGesture, DragGesture>.Value
    ) {
        guard case .second(true, let drag?) = value else {
            return
        }
        let threshold: CGFloat = 60
        guard drag.translation.width.magnitude >= threshold else {
            return
        }
        let direction = drag.translation.width < 0 ? 1 : -1
        onSwitch(direction)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
