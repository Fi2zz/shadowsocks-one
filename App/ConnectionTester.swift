import Foundation

struct ConnectionTestResult: Equatable {
    let statusCode: Int?
    let milliseconds: Int?
    let failureDescription: String?

    var succeeded: Bool {
        statusCode != nil
    }

    var summaryText: String {
        if let failureDescription {
            return "失败 · \(failureDescription)"
        }
        if let statusCode, let milliseconds {
            return "\(statusCode) · \(milliseconds)ms"
        }
        return "无响应"
    }
}

/// 连通性测试：经系统 VPN 通道向目标 URL 发 GET，验证连接节点后流量是否真的走通。
final class ConnectionTester: Sendable {
    typealias FetchHandler = @Sendable (URL) async throws -> HTTPURLResponse

    private static let requestTimeout: TimeInterval = 10

    private let fetch: FetchHandler

    init(fetch: FetchHandler? = nil) {
        self.fetch = fetch ?? Self.fetchOverSystemNetwork
    }

    func test(urlString: String) async -> ConnectionTestResult {
        guard let url = Self.normalizeURL(from: urlString) else {
            return ConnectionTestResult(
                statusCode: nil,
                milliseconds: nil,
                failureDescription: "地址无效"
            )
        }

        let start = ContinuousClock().now
        do {
            let response = try await fetch(url)
            return ConnectionTestResult(
                statusCode: response.statusCode,
                milliseconds: Self.milliseconds(since: start),
                failureDescription: nil
            )
        } catch {
            return ConnectionTestResult(
                statusCode: nil,
                milliseconds: nil,
                failureDescription: error.localizedDescription
            )
        }
    }

    static func normalizeURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: candidate)
    }

    private static func fetchOverSystemNetwork(url: URL) async throws -> HTTPURLResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (_, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return httpResponse
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock().now - start
        return Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
