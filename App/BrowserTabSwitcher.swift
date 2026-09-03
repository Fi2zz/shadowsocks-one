import SharedCore
import SwiftUI

/// 宫格式全屏切换器：缩略图卡片网格（iPhone 两列、iPad 常规宽度三列），
/// 上下滚动浏览，左滑关闭，点按选中；底部工具条左侧 ＋、右侧「完成」，
/// 进入时自动滚动到当前标签。
struct BrowserTabSwitcherView: View {
    @ObservedObject private var tabManager = BrowserTabManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                cardGrid(containerWidth: proxy.size.width)
                bottomBar
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var columnCount: Int {
        sizeClass == .regular ? 3 : 2
    }

    private func cardGrid(containerWidth: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: gridGap) {
                    ForEach(tabManager.tabs) { tab in
                        card(for: tab, width: cardWidth(in: containerWidth))
                            .id(tab.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 40)
                .padding(.bottom, 120)
            }
            .onAppear {
                if let id = tabManager.activeTabID {
                    reader.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var gridGap: CGFloat { 14 }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridGap), count: columnCount)
    }

    private func cardWidth(in containerWidth: CGFloat) -> CGFloat {
        let edge: CGFloat = 16
        let totalGap = gridGap * CGFloat(columnCount - 1)
        return (containerWidth - edge * 2 - totalGap) / CGFloat(columnCount)
    }

    private func card(for tab: BrowserTab, width: CGFloat) -> some View {
        BrowserTabCard(
            tab: tab,
            width: width,
            selected: tab.id == tabManager.activeTabID,
            onClose: { tabManager.closeTab(tab.id) },
            onSelect: {
                tabManager.selectTab(tab.id)
                dismiss()
            }
        )
    }

    private var bottomBar: some View {
        HStack {
            Button(action: newTabAndDismiss) {
                Image(systemName: "plus")
                    .font(.title2)
            }
            Spacer()
            Button("完成") { dismiss() }
        }
        .padding()
        .background(.bar)
    }

    private func newTabAndDismiss() {
        tabManager.createTab()
        dismiss()
    }
}
