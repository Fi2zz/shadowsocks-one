import Foundation
import SharedCore

/// 增量拉取结果：304 表示远端未变化，无需下载正文与落盘
enum CNIPListFetchResult {
    case notModified
    case modified(Data, etag: String?)
}

typealias CNIPListFetching = (String, String?) async throws -> CNIPListFetchResult

@MainActor
final class IPListViewModel: ObservableObject {
    static let defaultSourceURL = "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
    private static let sourceURLDefaultsKey = "cnIPListSourceURL"
    private static let updatedAtDefaultsKey = "cnIPListUpdatedAt"
    private static let etagDefaultsKey = "cnIPListETag"
    private static let upToDateMessage = "国内 IP 库已是最新，无需更新。"

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
    private let fetch: CNIPListFetching
    private let defaults: UserDefaults

    init(
        store: CNIPListStore?,
        fetch: @escaping CNIPListFetching,
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
            let result = try await fetch(urlString, currentETag(for: urlString))
            try apply(result, sourceURL: urlString)
        } catch {
            message = "国内 IP 库更新失败：\(error.localizedDescription)"
        }
    }

    private func apply(_ result: CNIPListFetchResult, sourceURL: String) throws {
        guard case .modified(let data, let etag) = result else {
            message = Self.upToDateMessage
            return
        }

        let content = try validatedContent(from: data)
        persistFetchState(etag: etag, sourceURL: sourceURL)
        guard content != (try? store?.load()) else {
            message = Self.upToDateMessage
            return
        }

        try store?.save(content)
        rangeCount = content.split(whereSeparator: \.isNewline).count
        updatedAt = Date()
        defaults.set(updatedAt, forKey: Self.updatedAtDefaultsKey)
        message = "国内 IP 库已更新，下次连接生效。"
    }

    /// ETag 只在来源 URL 未变时携带，避免换源后误命中 304
    private func currentETag(for urlString: String) -> String? {
        let storedURL = defaults.string(forKey: Self.sourceURLDefaultsKey)
        guard storedURL == urlString else {
            return nil
        }
        return defaults.string(forKey: Self.etagDefaultsKey)
    }

    private func persistFetchState(etag: String?, sourceURL: String) {
        defaults.set(etag, forKey: Self.etagDefaultsKey)
        defaults.set(sourceURL, forKey: Self.sourceURLDefaultsKey)
    }

    private func load() {
        if let content = try? store?.load() {
            rangeCount = content.split(whereSeparator: \.isNewline).count
        }
        updatedAt = defaults.object(forKey: Self.updatedAtDefaultsKey) as? Date
    }

    private func validatedContent(from data: Data) throws -> String {
        guard let content = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        _ = try CNIPRangeList(textContent: content)
        return content
    }

    private static func fetchContent(_ urlString: String, etag: String?) async throws -> CNIPListFetchResult {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try parseResponse(data: data, response: response)
    }

    private static func parseResponse(data: Data, response: URLResponse) throws -> CNIPListFetchResult {
        guard let http = response as? HTTPURLResponse else {
            return .modified(data, etag: nil)
        }
        if http.statusCode == 304 {
            return .notModified
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return .modified(data, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}
