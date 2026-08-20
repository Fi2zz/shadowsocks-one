import XCTest
@testable import SharedCore

final class ProfileMappingTests: XCTestCase {
    func testBuildsConnectionConfigFromProfile() {
        let profile = ServerProfile(
            host: "example.com",
            port: 8388,
            method: .chacha20IETFPoly1305,
            password: "secret",
            remark: "demo"
        )

        let config = ConnectionConfig(profile: profile)

        XCTAssertEqual(config.host, "example.com")
        XCTAssertEqual(config.port, 8388)
        XCTAssertEqual(config.method, .chacha20IETFPoly1305)
        XCTAssertEqual(config.password, "secret")
    }

    func testUsesRemarkAsDisplayName() {
        let profile = ServerProfile(
            host: "example.com",
            port: 8388,
            method: .aes128GCM,
            password: "secret",
            remark: "Tokyo"
        )

        XCTAssertEqual(profile.displayName, "Tokyo")
        XCTAssertEqual(profile.subtitle, "aes-128-gcm • example.com:8388")
    }
}
