import XCTest
@testable import SharedCore

final class PacketTunnelConnectionTests: XCTestCase {
    func testFailsImmediatelyForPluginProfile() async {
        let manager = ConnectionManager()
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
}
