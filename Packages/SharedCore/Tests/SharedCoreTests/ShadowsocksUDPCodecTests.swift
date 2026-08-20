import XCTest
@testable import SharedCore

final class ShadowsocksUDPCodecTests: XCTestCase {
    func testRoundTripsIPv4DatagramWithAES256GCM() throws {
        let codec = makeCodec(method: .aes256GCM)
        let datagram = try codec.seal(payload: Data("ping".utf8), toHost: "93.184.216.34", port: 443)

        let opened = try codec.open(datagram)

        XCTAssertEqual(opened.host, "93.184.216.34")
        XCTAssertEqual(opened.port, 443)
        XCTAssertEqual(opened.payload, Data("ping".utf8))
    }

    func testRoundTripsDomainDatagramWithChaCha20() throws {
        let codec = makeCodec(method: .chacha20IETFPoly1305)
        let datagram = try codec.seal(payload: Data("qua".utf8), toHost: "example.com", port: 8443)

        let opened = try codec.open(datagram)

        XCTAssertEqual(opened.host, "example.com")
        XCTAssertEqual(opened.port, 8443)
        XCTAssertEqual(opened.payload, Data("qua".utf8))
    }

    func testRoundTripsIPv6Datagram() throws {
        let codec = makeCodec(method: .aes128GCM)
        let datagram = try codec.seal(payload: Data("v6".utf8), toHost: "::1", port: 53)

        let opened = try codec.open(datagram)

        XCTAssertEqual(opened.host, "::1")
        XCTAssertEqual(opened.port, 53)
        XCTAssertEqual(opened.payload, Data("v6".utf8))
    }

    func testSealUsesFreshSaltPerDatagram() throws {
        let codec = makeCodec(method: .aes256GCM)
        let first = try codec.seal(payload: Data("x".utf8), toHost: "1.1.1.1", port: 443)
        let second = try codec.seal(payload: Data("x".utf8), toHost: "1.1.1.1", port: 443)

        XCTAssertNotEqual(first, second)
    }

    func testOpenFailsWithWrongMasterKey() throws {
        let codec = makeCodec(method: .aes256GCM)
        let datagram = try codec.seal(payload: Data("ping".utf8), toHost: "1.1.1.1", port: 443)
        let other = ShadowsocksUDPPacketCodec(
            method: .aes256GCM,
            masterKey: Data(repeating: 0x22, count: 32)
        )

        XCTAssertThrowsError(try other.open(datagram))
    }

    func testOpenFailsOnTruncatedDatagram() {
        let codec = makeCodec(method: .aes256GCM)

        XCTAssertThrowsError(try codec.open(Data(count: 10))) { error in
            XCTAssertEqual(error as? ShadowsocksUDPPacketCodecError, .truncatedDatagram)
        }
    }

    func testOpenFailsOnUnknownAddressType() throws {
        let codec = makeCodec(method: .aes256GCM)
        let salt = Data(repeating: 0x07, count: CipherMethod.aes256GCM.saltSize)
        let subkey = ShadowsocksSessionKey.makeSubkey(
            masterKey: Data(repeating: 0x11, count: 32),
            salt: salt,
            method: .aes256GCM
        )
        let ciphertext = try ShadowsocksAEADCipher.seal(
            Data([0x05, 0x00, 0x00]),
            method: .aes256GCM,
            subkey: subkey,
            nonce: Data(count: CipherMethod.aes256GCM.nonceSize)
        )

        XCTAssertThrowsError(try codec.open(salt + ciphertext)) { error in
            XCTAssertEqual(error as? ShadowsocksUDPPacketCodecError, .unknownAddressType(0x05))
        }
    }

    private func makeCodec(method: CipherMethod) -> ShadowsocksUDPPacketCodec {
        ShadowsocksUDPPacketCodec(
            method: method,
            masterKey: Data(repeating: 0x11, count: method.keySize)
        )
    }
}
