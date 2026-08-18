import Foundation
import Network

enum TCPRelayError: Error, Equatable {
    case invalidPort(UInt16)
    case connectionCancelled
}

final class DirectTCPRelay: TCPFlowRelaying {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ShadowsocksOne.PacketTunnel.DirectTCPRelay")
    private let stateLock = NSLock()
    private var didStart = false
    private var receiveTask: Task<Void, Never>?
    var onInboundBytes: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw TCPRelayError.invalidPort(port)
        }

        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: .tcp
        )
    }

    func start() async throws {
        guard markStartedIfNeeded() else {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            let resume = ContinuationResumer<Void>(continuation)
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .ready:
                    connection?.stateUpdateHandler = nil
                    resume.resume(returning: ())
                case .failed(let error):
                    connection?.stateUpdateHandler = nil
                    resume.resume(throwing: error)
                case .cancelled:
                    connection?.stateUpdateHandler = nil
                    resume.resume(throwing: TCPRelayError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        guard !payload.isEmpty else {
            return
        }

        try await start()
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

    func stop() async {
        receiveTask?.cancel()
        receiveTask = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func markStartedIfNeeded() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !didStart else {
            return false
        }

        didStart = true
        return true
    }

    private func runReceiveLoop() async {
        while !Task.isCancelled {
            do {
                let chunk = try await receiveChunk()
                if chunk.isEmpty {
                    break
                }

                await onInboundBytes?(chunk)
            } catch {
                break
            }
        }

        await onClosed?()
    }

    private func receiveChunk(maximumLength: Int = 4096) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: data ?? Data())
            }
        }
    }
}

private final class ContinuationResumer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
