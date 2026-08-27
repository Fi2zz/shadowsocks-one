import Foundation
import Network
import XCTest
@testable import ShadowsocksBrowserPacketTunnel

/// 用真实 NWConnection 走一遍 DirectTCPRelay 数据面：
/// 本地 echo 服务器 → relay 发出 → echo 回来 → onInboundBytes 收到原文。
final class DirectTCPRelayLoopbackTests: XCTestCase {
    func testEchoesPayloadThroughRealConnection() async throws {
        let echoServer = try LocalTCPEchoServer()
        try await echoServer.start()
        defer { echoServer.stop() }

        let relay = try DirectTCPRelay(host: "127.0.0.1", port: echoServer.port)
        let inbox = InboundRecorder()
        relay.onInboundBytes = { data in
            await inbox.record(data)
        }

        try await relay.start()
        try await relay.forwardOutboundPayload(Data("ping".utf8))

        try await assertEventually({ await inbox.received }, equals: Data("ping".utf8))
        await relay.stop()
    }

    private func assertEventually(
        _ actual: @escaping () async -> Data,
        equals expected: Data,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await actual() == expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let finalValue = await actual()
        XCTAssertEqual(finalValue, expected)
    }
}

private actor InboundRecorder {
    private(set) var received = Data()

    func record(_ data: Data) {
        received.append(data)
    }
}

private final class LocalTCPEchoServer: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.echoLoop(on: connection)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    self.port = self.listener.port?.rawValue ?? 0
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

    private static func echoLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
            guard let data, !data.isEmpty, error == nil else {
                connection.cancel()
                return
            }

            connection.send(content: data, completion: .contentProcessed { _ in
                echoLoop(on: connection)
            })
        }
    }
}
