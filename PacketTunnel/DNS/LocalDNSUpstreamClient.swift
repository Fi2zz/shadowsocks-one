import Foundation
import Network
import SharedCore

enum LocalDNSUpstreamError: Error, Equatable {
    case timeout
    case closed
}

/// 直连域名的 DNS 经本地 UDP 上游解析（默认阿里 223.5.5.5），
/// 让直连流量拿到本地最优的 CDN IP；代理域名仍走远程解析防污染。
final class LocalDNSUpstreamClient: DNSPayloadQuerying {
    private let resolverHost: String
    private let timeoutNanoseconds: UInt64

    init(
        resolverHost: String = "223.5.5.5",
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.resolverHost = resolverHost
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func query(serverIP: String, payload: Data) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.performQuery(payload: payload)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                throw LocalDNSUpstreamError.timeout
            }
            defer { group.cancelAll() }

            return try await group.next()!
        }
    }

    private func performQuery(payload: Data) async throws -> Data {
        let connection = NWConnection(
            host: NWEndpoint.Host(resolverHost),
            port: NWEndpoint.Port(rawValue: 53)!,
            using: .udp
        )
        defer { connection.cancel() }

        try await waitUntilReady(connection)
        try await send(payload, over: connection)
        return try await receiveResponse(from: connection)
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    private func send(_ payload: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveResponse(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { content, _, _, error in
                if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: error ?? LocalDNSUpstreamError.closed)
                }
            }
        }
    }
}
