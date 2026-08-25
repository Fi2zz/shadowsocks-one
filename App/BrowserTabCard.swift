import SharedCore
import SwiftUI

/// 切换器卡片：标题栏 + 页面缩略图；左滑关闭（带飞出/回弹动画），点按选中。
struct BrowserTabCard: View {
    let tab: BrowserTab
    let width: CGFloat
    let selected: Bool
    var onClose: () -> Void
    var onSelect: () -> Void

    @State private var offsetX: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            thumbnail
        }
        .frame(width: width, height: width * 0.72)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(border)
        .offset(x: offsetX)
        .opacity(1 - abs(offsetX) / width)
        .onTapGesture(perform: onSelect)
        .gesture(swipeToClose)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if selected {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.tint)
            }
            Text(tab.title)
                .lineLimit(1)
                .font(.subheadline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.bold())
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var thumbnail: some View {
        GeometryReader { proxy in
            Group {
                if let image = BrowserTabManager.shared.snapshotImage(for: tab) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // 后台未加载的标签无快照，显示占位图
                    Image(systemName: "globe")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .background(Color(uiColor: .systemBackground))
                }
            }
        }
        .clipped()
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 14)
            .stroke(selected ? Color.accentColor : Color(uiColor: .separator), lineWidth: selected ? 2 : 0.5)
    }

    /// 只在明确横向（左）滑动时接管，避免与纵向滚动冲突
    private var swipeToClose: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let translation = value.translation
                guard translation.width < 0, abs(translation.width) > abs(translation.height) else {
                    return
                }
                offsetX = translation.width
            }
            .onEnded { value in
                if value.translation.width < -width * 0.35 {
                    withAnimation(.easeOut(duration: 0.2)) { offsetX = -width }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: onClose)
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { offsetX = 0 }
                }
            }
    }
}
