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
        try await Task.sleep(nanoseconds: 220_000_000)
        let connectedState = await manager.state
        XCTAssertEqual(connectedState, .connected)

        await manager.disconnect()
        try await Task.sleep(nanoseconds: 20_000_000)
        let idleState = await manager.state
        XCTAssertEqual(idleState, .idle)
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
