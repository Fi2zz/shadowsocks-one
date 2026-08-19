import Foundation
import Network

public enum ShadowsocksTCPTransportError: Error, Equatable, Sendable {
    case invalidServerPort(UInt16)
    case encoderUnavailable
    case connectionCancelled
}

public final class ShadowsocksTCPTransport {
    private let config: ConnectionConfig
    private let masterKey: Data
    private let addressHeader: Data
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "SharedCore.ShadowsocksTCPTransport")
    private let stateLock = NSLock()
    private var didStart = false
    private var startupTask: Task<Void, Error>?
    private var encoder: ShadowsocksStreamEncoder?
    private var pendingSalt: Data?
    private var responseDecoder: ShadowsocksResponseDecoder
    private var didSendTargetHeader = false

    public init(
        config: ConnectionConfig,
        destinationHost: String,
        destinationPort: UInt16
    ) throws {
        guard let serverPort = NWEndpoint.Port(rawValue: config.port) else {
            throw ShadowsocksTCPTransportError.invalidServerPort(config.port)
        }

        self.config = config
        self.masterKey = ShadowsocksSessionKey.makeMasterKey(config: config)
        self.addressHeader = ShadowsocksAddressEncoder.encode(
            host: destinationHost,
            port: destinationPort
        )
        self.connection = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: serverPort,
            using: .tcp
        )
        self.responseDecoder = ShadowsocksResponseDecoder(
            method: config.method,
            masterKey: masterKey
        )
    }

    public func start() async throws {
        guard markStartedIfNeeded() else {
            return
        }

        let task = Task {
            try await self.performStartup()
        }
        stateLock.withLock {
            startupTask = task
        }
    }

    public func waitUntilReady() async throws {
        let task = stateLock.withLock { startupTask }
        try await task?.value
    }

    public func send(_ payload: Data) async throws {
        try await start()
        try await waitUntilReady()

        let outbound = try encodeOutboundPayload(payload)
        guard !outbound.isEmpty else {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: outbound, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            })
        }
    }

    public func receivePayloads(maximumLength: Int = 4096) async throws -> [Data] {
        try await start()
        try await waitUntilReady()

        let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
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

        guard !chunk.isEmpty else {
            return []
        }

        return try stateLock.withLock {
            responseDecoder.append(chunk)
            return try responseDecoder.readPayloads()
        }
    }

    public func stop() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func performStartup() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let resume = SharedContinuationResumer<Void>(continuation)
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
                    resume.resume(throwing: ShadowsocksTCPTransportError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        try prepareEncoder()
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

    private func prepareEncoder() throws {
        if stateLock.withLock({ encoder != nil }) {
            return
        }

        let salt = try RandomBytes.generate(count: config.method.saltSize)
        let subkey = ShadowsocksSessionKey.makeSubkey(
            masterKey: masterKey,
            salt: salt,
            method: config.method
        )

        stateLock.withLock {
            guard encoder == nil else {
                return
            }

            encoder = ShadowsocksStreamEncoder(
                method: config.method,
                subkey: subkey
            )
            pendingSalt = salt
        }
    }

    private func encodeOutboundPayload(_ payload: Data) throws -> Data {
        try stateLock.withLock {
            guard var encoder else {
                throw ShadowsocksTCPTransportError.encoderUnavailable
            }

            var data = Data()
            if let pendingSalt {
                data.append(pendingSalt)
                self.pendingSalt = nil
            }

            if !didSendTargetHeader {
                data.append(try encoder.encodeChunk(addressHeader))
                didSendTargetHeader = true
            }

            if !payload.isEmpty {
                data.append(try encoder.encodeChunk(payload))
            }

            self.encoder = encoder
            return data
        }
    }
}

private final class SharedContinuationResumer<T>: @unchecked Sendable {
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
