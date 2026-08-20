import Foundation
import Network

public enum ShadowsocksUDPTransportError: Error, Equatable, Sendable {
    case invalidServerPort(UInt16)
    case connectionCancelled
    case connectionClosed
}

public final class ShadowsocksUDPTransport {
    private let codec: ShadowsocksUDPPacketCodec
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "SharedCore.ShadowsocksUDPTransport")
    private let stateLock = NSLock()
    private var didStart = false
    private var startupTask: Task<Void, Error>?

    public init(config: ConnectionConfig) throws {
        guard let serverPort = NWEndpoint.Port(rawValue: config.port) else {
            throw ShadowsocksUDPTransportError.invalidServerPort(config.port)
        }

        self.codec = ShadowsocksUDPPacketCodec(
            method: config.method,
            masterKey: ShadowsocksSessionKey.makeMasterKey(config: config)
        )
        self.connection = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: serverPort,
            using: .udp
        )
    }

    public func start() async throws {
        guard markStartedIfNeeded() else {
            return
        }

        let task = Task {
            try await self.waitUntilConnectionReady()
        }
        stateLock.withLock {
            startupTask = task
        }
        try await task.value
    }

    public func send(payload: Data, toHost host: String, port: UInt16) async throws {
        try await start()

        let datagram = try codec.seal(payload: payload, toHost: host, port: port)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: datagram, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            })
        }
    }

    public func receive() async throws -> ShadowsocksUDPDatagram {
        try await start()

        let content = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { content, _, _, error in
                if let content {
                    continuation.resume(returning: content)
                    return
                }
                continuation.resume(throwing: error ?? ShadowsocksUDPTransportError.connectionClosed)
            }
        }
        return try codec.open(content)
    }

    public func stop() {
        connection.stateUpdateHandler = nil
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

    private func waitUntilConnectionReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let resume = SharedUDPContinuationResumer<Void>(continuation)
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
                    resume.resume(throwing: ShadowsocksUDPTransportError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}

private final class SharedUDPContinuationResumer<T>: @unchecked Sendable {
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
