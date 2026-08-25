import SwiftUI

/// Safari 式全屏切换器：卡片纵向堆叠、带 3D 透视倾斜、上部重叠，
/// 上下滚动浏览，左滑关闭，点按选中；底部工具条左侧 ＋、右侧「完成」，
/// 进入时自动滚动到当前标签。
struct BrowserTabSwitcherView: View {
    @ObservedObject private var tabManager = BrowserTabManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = proxy.size.width - 32
            ZStack(alignment: .bottom) {
                cardStack(width: cardWidth, screenHeight: proxy.size.height)
                bottomBar
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func cardStack(width: CGFloat, screenHeight: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: -width * 0.72 * 0.72) {
                    cards(width: width, screenHeight: screenHeight)
                }
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

    @ViewBuilder
    private func cards(width: CGFloat, screenHeight: CGFloat) -> some View {
        ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
            GeometryReader { geo in
                let distance = (geo.frame(in: .global).midY - screenHeight / 2) / screenHeight
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
                .rotation3DEffect(
                    .degrees(distance * 13),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.9
                )
            }
            .frame(width: width, height: width * 0.72)
            .zIndex(Double(index))
            .id(tab.id)
        }
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
