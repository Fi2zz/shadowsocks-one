import Foundation
import Network
import SharedCore

enum UDPUpstreamClientError: Error, Equatable {
    case invalidServerPort
    case connectionCancelled
    case emptyResponse
}

/// 基于 NWConnection 的单发单收 UDP 上游 DNS 客户端，
/// 替代已废弃的 NEProvider.createUDPSession。
final class UDPUpstreamClient: DNSPayloadQuerying {
    private let queue = DispatchQueue(label: "ShadowsocksOne.PacketTunnel.UDPUpstreamClient")

    func query(serverIP: String, payload: Data) async throws -> Data {
        guard let port = NWEndpoint.Port(rawValue: 53) else {
            throw UDPUpstreamClientError.invalidServerPort
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(serverIP),
            port: port,
            using: .udp
        )

        return try await withTaskCancellationHandler {
            try await performRoundTrip(on: connection, payload: payload)
        } onCancel: {
            connection.cancel()
        }
    }

    private func performRoundTrip(
        on connection: NWConnection,
        payload: Data
    ) async throws -> Data {
        try await waitUntilReady(connection)
        try await send(payload, on: connection)
        let response = try await receiveDatagram(on: connection)
        connection.cancel()
        return response
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let resume = ContinuationGate<Void>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    resume.resume(returning: ())
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    resume.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    resume.resume(throwing: UDPUpstreamClientError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ payload: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            })
        }
    }

    private func receiveDatagram(on connection: NWConnection) async throws -> Data {
        let datagram = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
        }

        guard !datagram.isEmpty else {
            throw UDPUpstreamClientError.emptyResponse
        }
        return datagram
    }
}

private final class ContinuationGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(throwing: error)
    }
}
