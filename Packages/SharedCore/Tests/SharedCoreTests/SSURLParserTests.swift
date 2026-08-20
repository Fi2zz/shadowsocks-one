import XCTest
@testable import SharedCore

final class SSURLParserTests: XCTestCase {
    func testParsesSIP002Base64URL() throws {
        let profile = try SSURLParser().parse("ss://YWVzLTEyOC1nY206cGFzcw@example.com:8388#demo")
        XCTAssertEqual(profile.host, "example.com")
        XCTAssertEqual(profile.port, 8388)
        XCTAssertEqual(profile.method, .aes128GCM)
        XCTAssertEqual(profile.password, "pass")
        XCTAssertEqual(profile.remark, "demo")
    }

    func testParsesLegacyWholeBase64() throws {
        let raw = "ss://YWVzLTI1Ni1nY206cGFzc0AxMjcuMC4wLjE6ODM4OA==#legacy"
        let profile = try SSURLParser().parse(raw)
        XCTAssertEqual(profile.host, "127.0.0.1")
        XCTAssertEqual(profile.method, .aes256GCM)
        XCTAssertEqual(profile.remark, "legacy")
    }

    func testParsesClearTextUserInfo() throws {
        let raw = "ss://aes-256-gcm:secret@example.com:8388#clear"
        let profile = try SSURLParser().parse(raw)

        XCTAssertEqual(profile.host, "example.com")
        XCTAssertEqual(profile.port, 8388)
        XCTAssertEqual(profile.method, .aes256GCM)
        XCTAssertEqual(profile.password, "secret")
        XCTAssertEqual(profile.remark, "clear")
    }

    func testParsesPluginValue() throws {
        let raw = "ss://YWVzLTEyOC1nY206cGFzcw@example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp#demo"
        let profile = try SSURLParser().parse(raw)

        XCTAssertEqual(profile.plugin, "obfs-local")
        XCTAssertEqual(profile.pluginOptions, "obfs=http")
    }

    func testSupportsBase64WithoutPadding() throws {
        let raw = "ss://YWVzLTEyOC1nY206cGFzcw@example.com:8388"
        let profile = try SSURLParser().parse(raw)

        XCTAssertEqual(profile.method, .aes128GCM)
        XCTAssertEqual(profile.password, "pass")
    }

    func testRejectsInvalidScheme() {
        XCTAssertThrowsError(
            try SSURLParser().parse("ssx://YWVzLTEyOC1nY206cGFzcw@example.com:8388")
        ) { error in
            XCTAssertEqual(error as? SSURLParseError, .invalidScheme)
        }
    }

    func testRejectsUnsupportedCipher() {
        XCTAssertThrowsError(
            try SSURLParser().parse("ss://cmM0LW1kNTpwYXNz@example.com:8388")
        )
    }
}
