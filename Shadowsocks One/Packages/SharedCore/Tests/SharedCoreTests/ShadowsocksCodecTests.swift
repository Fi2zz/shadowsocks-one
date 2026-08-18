import XCTest
@testable import SharedCore

final class ShadowsocksCodecTests: XCTestCase {
    func testEVPBytesToKeyDerivesExpectedPrefix() {
        let key = EVPBytesToKey.derive(password: "secret", keySize: 16)
        XCTAssertEqual(
            key.map { String(format: "%02x", $0) }.joined(),
            "5ebe2294ecd0e0f08eab7690d2a6ee69"
        )
    }

    func testHKDFSHA1DerivesExpectedKey() {
        let derived = HKDFSHA1.derive(
            inputKey: Data("secret".utf8),
            salt: Data(repeating: 0x01, count: 16),
            info: Data("ss-subkey".utf8),
            outputSize: 16
        )

        XCTAssertEqual(
            derived.map { String(format: "%02x", $0) }.joined(),
            "10b00a1907cd6dc8892bc92f77cef229"
        )
    }

    func testRoundTripsEncryptedChunk() throws {
        let subkey = Data(repeating: 0x11, count: 16)
        var encoder = ShadowsocksStreamEncoder(method: .aes128GCM, subkey: subkey)
        let chunk = try encoder.encodeChunk(Data("hello".utf8))

        var decoder = ShadowsocksStreamDecoder(method: .aes128GCM, subkey: subkey)
        decoder.append(chunk)

        XCTAssertEqual(try decoder.readPayloads(), [Data("hello".utf8)])
    }
}
