import SwiftUI
import SharedCore

struct BrowserHistoryView: View {
    @ObservedObject var tabManager: BrowserTabManager
    let openURL: (URL) -> Void

    var body: some View {
        List(tabManager.history) { entry in
            Button {
                openURL(entry.url)
            } label: {
                historyRow(entry)
            }
        }
        .navigationTitle("历史记录")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空") { tabManager.clearHistory() }
                    .disabled(tabManager.history.isEmpty)
            }
        }
        .overlay {
            if tabManager.history.isEmpty {
                ContentUnavailableView("暂无历史记录", systemImage: "clock")
            }
        }
    }

    private func historyRow(_ entry: BrowserHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(entry.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
