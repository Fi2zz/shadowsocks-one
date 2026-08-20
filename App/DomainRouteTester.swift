import Foundation
import Network
import SharedCore

struct DomainRouteTestResult: Equatable {
    let decision: RouteDecision
    let addresses: [String]
    let connectMilliseconds: Int?
    let failureDescription: String?

    var summaryText: String {
        if decision == .proxy {
            return "走代理"
        }
        if let connectMilliseconds {
            return "直连 · \(connectMilliseconds)ms"
        }
        return failureDescription.map { "直连 · \($0)" } ?? "直连"
    }
}

enum DomainRouteTestError: Error {
    case connectTimeout
    case connectFailed
}

/// 名单测试：本地解析域名 → 按当前配置跑分流决策 → 判定直连时实测 TCP 443 连通性。
final class DomainRouteTester: Sendable {
    private let resolver: any DNSResolving
    private let timeoutNanoseconds: UInt64

    init(
        resolver: any DNSResolving = SystemDNSResolver(),
        timeoutNanoseconds: UInt64 = 4_000_000_000
    ) {
        self.resolver = resolver
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func test(
        entry: String,
        configuration: RoutingConfiguration,
        cnIPRanges: CNIPRangeList
    ) async -> DomainRouteTestResult {
        let host = Self.testableHost(from: entry)
        let addresses = (try? await resolver.resolve(host: host)) ?? []
        let matcher = RouteMatcher(configuration: configuration, cnIPRanges: cnIPRanges)
        let decision = makeDecision(matcher: matcher, host: host, addresses: addresses)

        guard decision == .direct, !addresses.isEmpty else {
            return failureResult(decision: decision, addresses: addresses)
        }

        return await connectResult(host: host, addresses: addresses)
    }

    /// 通配名单项（*.suffix）只匹配子域名，测试时用 www 子域作为代表主机
    static func testableHost(from entry: String) -> String {
        let normalized = entry
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard normalized.hasPrefix("*.") else {
            return normalized
        }
        return "www." + normalized.dropFirst(2)
    }

    private func makeDecision(
        matcher: RouteMatcher,
        host: String,
        addresses: [String]
    ) -> RouteDecision {
        guard let firstAddress = addresses.first else {
            return matcher.dnsDecision(forHost: host)
        }
        return matcher.route(forHost: host, ipString: firstAddress)
    }

    private func failureResult(
        decision: RouteDecision,
        addresses: [String]
    ) -> DomainRouteTestResult {
        let failure = addresses.isEmpty ? "解析失败" : nil
        return DomainRouteTestResult(
            decision: decision,
            addresses: addresses,
            connectMilliseconds: nil,
            failureDescription: failure
        )
    }

    private func connectResult(host: String, addresses: [String]) async -> DomainRouteTestResult {
        do {
            let milliseconds = try await measureConnect(host: host)
            return DomainRouteTestResult(
                decision: .direct,
                addresses: addresses,
                connectMilliseconds: milliseconds,
                failureDescription: nil
            )
        } catch {
            return DomainRouteTestResult(
                decision: .direct,
                addresses: addresses,
                connectMilliseconds: nil,
                failureDescription: "连接失败"
            )
        }
    }

    private func measureConnect(host: String) async throws -> Int {
        let clock = ContinuousClock()
        let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitUntilConnected(host: host) }
            group.addTask {
                try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                throw DomainRouteTestError.connectTimeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
        let elapsed = clock.now - start
        return Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func waitUntilConnected(host: String) async throws {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: 443)!,
            using: .tcp
        )
        defer { connection.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed, .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: DomainRouteTestError.connectFailed)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }
}
