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

        // #region debug-point E:direct-relay-start
        TunnelDebugReporter.send(
            "E",
            location: "DirectTCPRelay.start",
            message: "starting direct relay"
        )
        // #endregion
        try await withCheckedThrowingContinuation { continuation in
            let resume = ContinuationResumer<Void>(continuation)
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .ready:
                    // #region debug-point E:direct-relay-ready
                    TunnelDebugReporter.send(
                        "E",
                        location: "DirectTCPRelay.start",
                        message: "direct relay ready"
                    )
                    // #endregion
                    connection?.stateUpdateHandler = nil
                    resume.resume(returning: ())
                case .failed(let error):
                    // #region debug-point E:direct-relay-failed
                    TunnelDebugReporter.send(
                        "E",
                        location: "DirectTCPRelay.start",
                        message: "direct relay failed",
                        data: ["error": error.localizedDescription]
                    )
                    // #endregion
                    connection?.stateUpdateHandler = nil
                    resume.resume(throwing: error)
                case .cancelled:
                    // #region debug-point E:direct-relay-cancelled
                    TunnelDebugReporter.send(
                        "E",
                        location: "DirectTCPRelay.start",
                        message: "direct relay cancelled before ready"
                    )
                    // #endregion
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

        // #region debug-point E:direct-relay-send
        TunnelDebugReporter.send(
            "E",
            location: "DirectTCPRelay.forwardOutboundPayload",
            message: "sending payload over direct relay",
            data: ["payloadBytes": payload.count]
        )
        // #endregion
        try await start()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    // #region debug-point E:direct-relay-send-failed
                    TunnelDebugReporter.send(
                        "E",
                        location: "DirectTCPRelay.forwardOutboundPayload",
                        message: "direct relay send failed",
                        data: ["error": error.localizedDescription]
                    )
                    // #endregion
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

                // #region debug-point E:direct-relay-receive
                TunnelDebugReporter.send(
                    "E",
                    location: "DirectTCPRelay.runReceiveLoop",
                    message: "direct relay received payload",
                    data: ["payloadBytes": chunk.count]
                )
                // #endregion
                await onInboundBytes?(chunk)
            } catch {
                // #region debug-point E:direct-relay-receive-failed
                TunnelDebugReporter.send(
                    "E",
                    location: "DirectTCPRelay.runReceiveLoop",
                    message: "direct relay receive loop failed",
                    data: ["error": error.localizedDescription]
                )
                // #endregion
                break
            }
        }

        // #region debug-point E:direct-relay-closed
        TunnelDebugReporter.send(
            "E",
            location: "DirectTCPRelay.runReceiveLoop",
            message: "direct relay receive loop closed"
        )
        // #endregion
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
