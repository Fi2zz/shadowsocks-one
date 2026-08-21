import SwiftUI

struct BrowserTabOverview: View {
    @ObservedObject var tabManager: BrowserTabManager
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(tabManager.tabs) { tab in
                        tabCard(tab)
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("标签页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                tabManager.addTab()
                dismiss()
            } label: {
                Image(systemName: "plus")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("完成") { dismiss() }
        }
    }

    private func tabCard(_ tab: WebViewStore) -> some View {
        cardContent(tab)
            .overlay(alignment: .topTrailing) { closeButton(tab) }
            .overlay(selectionBorder(for: tab))
            .contentShape(Rectangle())
            .onTapGesture { select(tab) }
    }

    private func cardContent(_ tab: WebViewStore) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tab.title)
                .font(.headline)
                .lineLimit(1)
            Text(tab.currentURL?.host ?? "新标签页")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .frame(height: 88, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func closeButton(_ tab: WebViewStore) -> some View {
        Button {
            tabManager.closeTab(id: tab.id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .padding(6)
    }

    private func selectionBorder(for tab: WebViewStore) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(
                tab.id == tabManager.selectedTabID ? Color.accentColor : .clear,
                lineWidth: 2
            )
    }

    private func select(_ tab: WebViewStore) {
        tabManager.selectTab(id: tab.id)
        dismiss()
    }
}
