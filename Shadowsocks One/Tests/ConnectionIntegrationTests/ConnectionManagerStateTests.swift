import Foundation
import XCTest
@testable import SharedCore

final class ConnectionManagerStateTests: XCTestCase {
    func testFailsImmediatelyForPluginProfile() async {
        let manager = ConnectionManager(probeClient: ProbeStub(script: []))
        let config = ConnectionConfig(
            host: "127.0.0.1",
            port: 9443,
            method: .aes128GCM,
            password: "pass"
        )

        await manager.connect(using: config, plugin: "obfs-local")
        let state = await manager.state

        XCTAssertEqual(state, .failed("当前版本暂不支持 plugin 节点连接"))
    }

    func testConnectsToLocalAEADServerAndDisconnects() async throws {
        let target = ConnectionProbeTarget(
            host: "example.com",
            port: 80,
            requestData: Data("HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n".utf8),
            responsePrefix: Data("HTTP/".utf8)
        )
        let config = ConnectionConfig(
            host: "127.0.0.1",
            port: 19443,
            method: .aes128GCM,
            password: "pass"
        )
        let server = try LocalAEADEchoServer(
            port: config.port,
            method: config.method,
            password: config.password,
            expectedRequest: target.requestData
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let manager = ConnectionManager(
            probeClient: ShadowsocksProbeClient(timeoutNanoseconds: 1_000_000_000),
            probeTarget: target,
            healthCheckNanoseconds: 1_000_000_000,
            reconnectNanoseconds: 50_000_000
        )

        await manager.connect(using: config, plugin: nil)
        try await assertEventually(state: .connected, manager: manager)
        await manager.disconnect()
        try await assertEventually(state: .idle, manager: manager)
    }

    func testReconnectsAfterFailureAndDisconnectStopsLoop() async throws {
        let probe = ProbeStub(script: [.failure("boom"), .success, .success])
        let manager = ConnectionManager(
            probeClient: probe,
            healthCheckNanoseconds: 50_000_000,
            reconnectNanoseconds: 50_000_000
        )
        let config = ConnectionConfig(
            host: "127.0.0.1",
            port: 9443,
            method: .aes128GCM,
            password: "pass"
        )

        await manager.connect(using: config, plugin: nil)
        try await assertEventually(state: .connected, manager: manager)
        await manager.disconnect()
        try await assertEventually(state: .idle, manager: manager)
    }

    private func assertEventually(
        state expected: ConnectionState,
        manager: ConnectionManager,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await manager.state == expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let currentState = await manager.state
        XCTAssertEqual(currentState, expected)
    }
}

private actor ProbeScriptBox {
    private var index = 0
    private let script: [ProbeAction]

    init(script: [ProbeAction]) {
        self.script = script
    }

    func next() -> ProbeAction {
        guard index < script.count else {
            return .success
        }
        defer { index += 1 }
        return script[index]
    }
}

private enum ProbeAction {
    case success
    case failure(String)
}

private struct ProbeStub: ShadowsocksProbing {
    private let box: ProbeScriptBox

    init(script: [ProbeAction]) {
        self.box = ProbeScriptBox(script: script)
    }

    func probe(using config: ConnectionConfig, target: ConnectionProbeTarget) async throws {
        switch await box.next() {
        case .success:
            return
        case let .failure(message):
            throw NSError(domain: "ProbeStub", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
