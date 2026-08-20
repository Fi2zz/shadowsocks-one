import Foundation
import SharedCore

@MainActor
final class IPListViewModel: ObservableObject {
    static let defaultSourceURL = "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
    private static let sourceURLDefaultsKey = "cnIPListSourceURL"
    private static let updatedAtDefaultsKey = "cnIPListUpdatedAt"

    @Published var sourceURL: String
    @Published private(set) var rangeCount = 0
    @Published private(set) var updatedAt: Date?
    @Published private(set) var updating = false
    @Published private(set) var message: String?

    var sourceURLEmpty: Bool {
        sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var statusText: String {
        guard rangeCount > 0 else {
            return "使用扩展内置列表"
        }
        guard let updatedAt else {
            return "已下载 \(rangeCount) 条"
        }
        let time = updatedAt.formatted(date: .numeric, time: .shortened)
        return "已下载 \(rangeCount) 条 · 更新于 \(time)"
    }

    private let store: CNIPListStore?
    private let fetch: (String) async throws -> Data
    private let defaults: UserDefaults

    init(
        store: CNIPListStore?,
        fetch: @escaping (String) async throws -> Data,
        defaults: UserDefaults
    ) {
        self.store = store
        self.fetch = fetch
        self.defaults = defaults
        self.sourceURL = defaults.string(forKey: Self.sourceURLDefaultsKey) ?? Self.defaultSourceURL
        load()
    }

    static func makeDefault() -> IPListViewModel {
        IPListViewModel(
            store: try? CNIPListStore(appGroupID: SharedContainerSettings.appGroupID),
            fetch: Self.fetchContent,
            defaults: .standard
        )
    }

    func update() async {
        let urlString = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else {
            return
        }

        updating = true
        defer { updating = false }

        do {
            let content = try await downloadValidatedContent(from: urlString)
            try store?.save(content)
            rangeCount = content.split(whereSeparator: \.isNewline).count
            updatedAt = Date()
            defaults.set(updatedAt, forKey: Self.updatedAtDefaultsKey)
            defaults.set(urlString, forKey: Self.sourceURLDefaultsKey)
            message = "国内 IP 库已更新，下次连接生效。"
        } catch {
            message = "国内 IP 库更新失败：\(error.localizedDescription)"
        }
    }

    private func load() {
        if let content = try? store?.load() {
            rangeCount = content.split(whereSeparator: \.isNewline).count
        }
        updatedAt = defaults.object(forKey: Self.updatedAtDefaultsKey) as? Date
    }

    private func downloadValidatedContent(from urlString: String) async throws -> String {
        let data = try await fetch(urlString)
        guard let content = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        _ = try CNIPRangeList(textContent: content)
        return content
    }

    private static func fetchContent(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}
