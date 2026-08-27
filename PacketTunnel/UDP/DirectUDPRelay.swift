import Foundation
import Network

enum UDPRelayError: Error, Equatable {
    case invalidPort(UInt16)
    case connectionCancelled
    case connectionClosed
}

final class DirectUDPRelay: UDPFlowRelaying {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ShadowsocksBrowser.PacketTunnel.DirectUDPRelay")
    private let stateLock = NSLock()
    private var didStart = false
    private var receiveTask: Task<Void, Never>?
    var onInboundDatagram: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw UDPRelayError.invalidPort(port)
        }

        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: .udp
        )
    }

    func start() async throws {
        guard markStartedIfNeeded() else {
            return
        }

        try await waitUntilReady()
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        guard !payload.isEmpty else {
            return
        }

        try await start()
        try await send(payload)
    }

    func stop() async {
        receiveTask?.cancel()
        receiveTask = nil
        connection.cancel()
    }

    private func markStartedIfNeeded() -> Bool {
        stateLock.withLock {
            guard !didStart else {
                return false
            }

            didStart = true
            return true
        }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let resume = UDPContinuationResumer<Void>(continuation)
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
                    resume.resume(throwing: UDPRelayError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ payload: Data) async throws {
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

    private func runReceiveLoop() async {
        while !Task.isCancelled {
            do {
                let datagram = try await receiveDatagram()
                await onInboundDatagram?(datagram)
            } catch {
                break
            }
        }

        await onClosed?()
    }

    private func receiveDatagram() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { content, _, _, error in
                if let content {
                    continuation.resume(returning: content)
                    return
                }

                continuation.resume(throwing: error ?? UDPRelayError.connectionClosed)
            }
        }
    }
}

private final class UDPContinuationResumer<T>: @unchecked Sendable {
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
