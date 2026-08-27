import Foundation
import Network

enum TCPRelayError: Error, Equatable {
    case invalidPort(UInt16)
    case connectionCancelled
}

final class DirectTCPRelay: TCPFlowRelaying {
    private let connection: NWConnection
    private let endpoint: String
    private let diagnostics: TunnelDiagnosticsLogging?
    private let queue = DispatchQueue(label: "ShadowsocksBrowser.PacketTunnel.DirectTCPRelay")
    private let stateLock = NSLock()
    private var didStart = false
    private var firstReceiveLogged = false
    private var receiveTask: Task<Void, Never>?
    private var inFlightOutboundBytes = 0
    var onInboundBytes: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    var queuedOutboundBytes: Int {
        stateLock.withLock { inFlightOutboundBytes }
    }

    init(
        host: String,
        port: UInt16,
        diagnostics: TunnelDiagnosticsLogging? = nil
    ) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw TCPRelayError.invalidPort(port)
        }

        self.endpoint = "\(host):\(port)"
        self.diagnostics = diagnostics
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

        do {
            try await waitUntilReady()
            diagnostics?("DIRECT \(endpoint) ready")
        } catch {
            diagnostics?("DIRECT \(endpoint) connect failed: \(error.localizedDescription)")
            throw error
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
        stateLock.withLock { inFlightOutboundBytes += payload.count }
        defer { stateLock.withLock { inFlightOutboundBytes -= payload.count } }
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

    private func waitUntilReady() async throws {
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
    }

    private func runReceiveLoop() async {
        while !Task.isCancelled {
            do {
                let chunk = try await receiveChunk()
                if chunk.isEmpty {
                    break
                }

                logFirstReceive(chunk)
                await onInboundBytes?(chunk)
            } catch {
                diagnostics?("DIRECT \(endpoint) recv error: \(error.localizedDescription)")
                break
            }
        }

        diagnostics?("DIRECT \(endpoint) closed")
        await onClosed?()
    }

    private func logFirstReceive(_ chunk: Data) {
        stateLock.withLock {
            guard !firstReceiveLogged else {
                return
            }

            firstReceiveLogged = true
            diagnostics?("DIRECT \(endpoint) recv \(chunk.count)B")
        }
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
