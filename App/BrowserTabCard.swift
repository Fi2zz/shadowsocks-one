import SharedCore
import SwiftUI

/// 切换器卡片（对齐 Safari 宫格）：整卡缩略图 + 右上角悬浮关闭钮，
/// 标题（globe 占位图标）显示在卡片下方居中；左滑关闭，点按选中。
struct BrowserTabCard: View {
    let tab: BrowserTab
    let width: CGFloat
    let selected: Bool
    var onClose: () -> Void
    var onSelect: () -> Void

    @State private var offsetX: CGFloat = 0

    private var thumbnailHeight: CGFloat { width * 1.15 }

    var body: some View {
        VStack(spacing: 8) {
            thumbnail
            titleLine
        }
        .offset(x: offsetX)
        .opacity(1 - abs(offsetX) / width)
        .onTapGesture(perform: onSelect)
        .gesture(swipeToClose)
    }

    private var thumbnail: some View {
        snapshot
            .frame(width: width, height: thumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(border)
            .overlay(alignment: .topTrailing) { closeButton }
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    private var snapshot: some View {
        GeometryReader { proxy in
            Group {
                if let image = BrowserTabManager.shared.snapshotImage(for: tab) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // 后台未加载的标签无快照，显示占位图
                    placeholder(in: proxy.size)
                }
            }
        }
    }

    private func placeholder(in size: CGSize) -> some View {
        Image(systemName: "globe")
            .font(.largeTitle)
            .foregroundStyle(.tertiary)
            .frame(width: size.width, height: size.height)
            .background(Color(uiColor: .secondarySystemBackground))
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tab.title)
                .lineLimit(1)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.footnote.bold())
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
        }
        .padding(6)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 14)
            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
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
