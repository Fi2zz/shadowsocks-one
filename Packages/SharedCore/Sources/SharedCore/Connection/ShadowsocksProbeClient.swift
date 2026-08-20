import Foundation
import Network

public struct ShadowsocksProbeClient: ShadowsocksProbing {
    private let timeoutNanoseconds: UInt64

    public init(timeoutNanoseconds: UInt64 = 8_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public func probe(using config: ConnectionConfig, target: ConnectionProbeTarget) async throws {
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            throw ShadowsocksProbeError.invalidPort
        }

        let requestData = try ShadowsocksRequestEncoder.encode(config: config, target: target)
        let masterKey = ShadowsocksSessionKey.makeMasterKey(config: config)
        let connection = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: .tcp)
        defer { connection.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runProbe(
                    connection: connection,
                    requestData: requestData,
                    masterKey: masterKey,
                    method: config.method,
                    target: target
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw ShadowsocksProbeError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func runProbe(
        connection: NWConnection,
        requestData: Data,
        masterKey: Data,
        method: CipherMethod,
        target: ConnectionProbeTarget
    ) async throws {
        try await waitUntilReady(for: connection)
        try await send(requestData, over: connection)

        var decoder = ShadowsocksResponseDecoder(method: method, masterKey: masterKey)
        var response = Data()

        while !Task.isCancelled {
            let chunk = try await receive(from: connection)
            guard !chunk.isEmpty else {
                throw ShadowsocksProbeError.connectionClosed
            }

            decoder.append(chunk)
            for payload in try decoder.readPayloads() {
                response.append(payload)
                if response.starts(with: target.responsePrefix) {
                    return
                }
                if response.count >= target.responsePrefix.count {
                    throw ShadowsocksProbeError.invalidResponse
                }
            }
        }
    }

    private func waitUntilReady(for connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume(returning: ())
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

    private func send(_ content: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: content, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            })
        }
    }

    private func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
        }
    }
}
