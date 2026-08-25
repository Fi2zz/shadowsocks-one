import SharedCore
import SwiftUI

/// 书签列表：点按在当前标签打开，左滑删除。
struct BrowserBookmarkListView: View {
    @ObservedObject var tabManager: BrowserTabManager
    let openURL: (URL) -> Void

    var body: some View {
        Group {
            if tabManager.bookmarks.isEmpty {
                ContentUnavailableView("暂无书签", systemImage: "star")
            } else {
                bookmarkList
            }
        }
        .navigationTitle("书签")
    }

    private var bookmarkList: some View {
        List {
            ForEach(tabManager.bookmarks) { entry in
                Button { openURL(entry.url) } label: {
                    row(entry)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        tabManager.removeBookmark(id: entry.id)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func row(_ entry: BrowserBookmarkEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title.isEmpty ? entry.url.host ?? entry.url.absoluteString : entry.title)
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
