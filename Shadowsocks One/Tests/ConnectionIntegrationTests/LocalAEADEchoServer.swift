import Foundation
import Network
@testable import SharedCore

actor LocalAEADEchoServer {
    private let listener: NWListener
    private let method: CipherMethod
    private let masterKey: Data
    private let expectedRequest: Data
    private let responseData: Data

    init(
        port: UInt16,
        method: CipherMethod,
        password: String,
        expectedRequest: Data,
        responseData: Data = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
    ) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw CocoaError(.coderInvalidValue)
        }
        self.listener = try NWListener(using: .tcp, on: endpointPort)
        self.method = method
        self.masterKey = EVPBytesToKey.derive(password: password, keySize: method.keySize)
        self.expectedRequest = expectedRequest
        self.responseData = responseData
    }

    func start() async throws {
        let method = self.method
        let masterKey = self.masterKey
        let expectedRequest = self.expectedRequest
        let responseData = self.responseData
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Task {
                defer { connection.cancel() }
                do {
                    try await Self.serve(
                        connection: connection,
                        method: method,
                        masterKey: masterKey,
                        expectedRequest: expectedRequest,
                        responseData: responseData
                    )
                } catch {
                    return
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: ())
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
    }

    private static func serve(
        connection: NWConnection,
        method: CipherMethod,
        masterKey: Data,
        expectedRequest: Data,
        responseData: Data
    ) async throws {
        let requestPayload = try await readRequest(
            from: connection,
            method: method,
            masterKey: masterKey
        )
        guard requestPayload == expectedRequest else {
            throw CocoaError(.coderReadCorrupt)
        }

        let response = try encodeResponse(
            responseData,
            method: method,
            masterKey: masterKey
        )
        try await send(response, over: connection)
    }

    private static func readRequest(
        from connection: NWConnection,
        method: CipherMethod,
        masterKey: Data
    ) async throws -> Data {
        var buffer = Data()
        var decoder: ShadowsocksStreamDecoder?
        var payloads: [Data] = []

        while payloads.count < 2 {
            let chunk = try await receive(from: connection)
            guard !chunk.isEmpty else {
                throw CocoaError(.coderReadCorrupt)
            }

            buffer.append(chunk)
            if decoder == nil, buffer.count >= method.saltSize {
                let salt = buffer.prefix(method.saltSize)
                buffer.removeFirst(method.saltSize)
                decoder = ShadowsocksStreamDecoder(
                    method: method,
                    subkey: ShadowsocksSessionKey.makeSubkey(
                        masterKey: masterKey,
                        salt: salt,
                        method: method
                    )
                )
            }

            guard var activeDecoder = decoder else {
                continue
            }
            activeDecoder.append(buffer)
            buffer.removeAll(keepingCapacity: true)
            payloads.append(contentsOf: try activeDecoder.readPayloads())
            decoder = activeDecoder
        }

        return payloads[1]
    }

    private static func encodeResponse(
        _ payload: Data,
        method: CipherMethod,
        masterKey: Data
    ) throws -> Data {
        let salt = try RandomBytes.generate(count: method.saltSize)
        let subkey = ShadowsocksSessionKey.makeSubkey(
            masterKey: masterKey,
            salt: salt,
            method: method
        )
        var encoder = ShadowsocksStreamEncoder(method: method, subkey: subkey)
        return salt + (try encoder.encodeChunk(payload))
    }

    private static func send(_ content: Data, over connection: NWConnection) async throws {
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

    private static func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
        }
    }
}
