import Foundation
import CryptoKit
import XCTest
@testable import SharedCore

/// WireGuard 核心离线验证：BLAKE2s 向量（hashlib 对齐）、HMAC/KDF、
/// 握手回环（模拟响应端）、会话加解与重放窗口。
final class WireGuardCryptoTests: XCTestCase {

    // MARK: - BLAKE2s

    func testBlake2sVectors() {
        let cases: [(Data, Data, Int, String)] = [
            (Data(), Data(), 32,
             "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9"),
            (Data("abc".utf8), Data(), 32,
             "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982"),
            (Data(repeating: UInt8(ascii: "a"), count: 200), Data(), 32,
             "2b033f9f5ba9cf20671da79e492f41545e673b562603945ffed09662fd92321a"),
            (Data(), Data((0..<32).map { UInt8($0) }), 32,
             "48a8997da407876b3d79c0d92325ad3b89cbb754d86ab71aee047ad345fd2c49"),
            (Data([1, 2, 3]), Data("mac1-key-example-1234567890abcd".utf8), 16,
             "8a4c4fb73effa682f83d00053f92dae6"),
        ]
        for (message, key, length, expected) in cases {
            let digest = Blake2s(digestLength: length, key: [UInt8](key)).hash([UInt8](message))
            XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(),
                           expected)
        }
    }

    func testHMACVectors() {
        XCTAssertEqual(
            WireGuardCrypto.hmac(Data("chain-key-example-1234567890abcdef".utf8),
                                 Data("input-keying-material".utf8))
                .map { String(format: "%02x", $0) }.joined(),
            "e6ded4cab55c9b7a8f98861c722427cb425c2a85ca49d66ea9c4262f75b01572")
        XCTAssertEqual(
            WireGuardCrypto.hmac(Data("k".utf8), Data())
                .map { String(format: "%02x", $0) }.joined(),
            "34a2997fa3790e363b3937d29a9cb44401508853ab99eea57f8a91db8218de6f")
    }

    func testKDFOutputsAreChained() {
        let ck = Data((0..<32).map { UInt8($0) })
        let pair = WireGuardCrypto.kdf2(ck, Data([1]))
        let triple = WireGuardCrypto.kdf3(ck, Data([1]))
        XCTAssertEqual(pair.0, triple.0)
        XCTAssertEqual(pair.1, triple.1)
        XCTAssertNotEqual(triple.0, triple.1)
        XCTAssertNotEqual(triple.1, triple.2)
    }

    // MARK: - 握手回环

    func testHandshakeLoopbackDerivesMatchingKeys() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderPublic = responderStatic.publicKey

        let initiation = try WireGuardHandshake.createInitiation(
            staticPrivate: initiatorStatic, peerStaticPublic: responderPublic)
        XCTAssertEqual(initiation.packet.count, 148)
        XCTAssertEqual(initiation.packet[initiation.packet.startIndex], 1)

        let simulated = try simulateResponderResponse(
            initiation: initiation,
            initiatorStaticPublic: initiatorStatic.publicKey,
            responderStatic: responderStatic)

        let keys = try WireGuardHandshake.processResponse(
            simulated.packet, initiation: initiation,
            staticPrivate: initiatorStatic)

        XCTAssertEqual(keys.peerIndex, simulated.responderIndex)
        XCTAssertEqual(Data(keys.send.withUnsafeBytes { Data($0) }),
                       simulated.responderReceiveKey,
                       "发起方发送钥应等于响应方接收钥")
        XCTAssertEqual(Data(keys.receive.withUnsafeBytes { Data($0) }),
                       simulated.responderSendKey,
                       "发起方接收钥应等于响应方发送钥")
    }

    /// 以响应方身份走完整状态机，构造合法 type=2 包并给出己方密钥。
    private func simulateResponderResponse(
        initiation: WireGuardHandshake.Initiation,
        initiatorStaticPublic: Curve25519.KeyAgreement.PublicKey,
        responderStatic: Curve25519.KeyAgreement.PrivateKey
    ) throws -> (packet: Data, responderIndex: UInt32,
                 responderReceiveKey: Data, responderSendKey: Data) {
        let p = [UInt8](initiation.packet)
        let ephemeralPubI = Data(p[8..<40])
        let encryptedStatic = Data(p[40..<88])
        let encryptedTimestamp = Data(p[88..<116])
        let ephemeralPubIKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPubI)

        var chain = WireGuardCrypto.hash(Data(WireGuardCrypto.construction.utf8))
        var hash = WireGuardCrypto.hash(chain, Data(WireGuardCrypto.identifier.utf8))
        hash = WireGuardCrypto.hash(hash, Data(responderStatic.publicKey.rawRepresentation))
        hash = WireGuardCrypto.hash(hash, ephemeralPubI)
        chain = WireGuardCrypto.kdf1(chain, ephemeralPubI)
        let (chainA, staticOpen) = WireGuardCrypto.kdf2(chain, try dh(responderStatic, ephemeralPubIKey))
        let staticPlain = try WireGuardCrypto.aeadOpen(
            SymmetricKey(data: staticOpen), counter: 0,
            combined: encryptedStatic, aad: hash)
        XCTAssertEqual(staticPlain, Data(initiatorStaticPublic.rawRepresentation))
        hash = WireGuardCrypto.hash(hash, encryptedStatic)

        let initiatorStaticKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: staticPlain)
        let (chainB, timestampKey) = WireGuardCrypto.kdf2(chainA, try dh(responderStatic, initiatorStaticKey))
        let timestamp = try WireGuardCrypto.aeadOpen(
            SymmetricKey(data: timestampKey), counter: 0,
            combined: encryptedTimestamp, aad: hash)
        XCTAssertEqual(timestamp.count, 12)
        hash = WireGuardCrypto.hash(hash, encryptedTimestamp)

        let responderEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let responderIndex = UInt32.random(in: 1...UInt32.max)
        let responderEphemeralPub = Data(responderEphemeral.publicKey.rawRepresentation)
        hash = WireGuardCrypto.hash(hash, responderEphemeralPub)
        chain = WireGuardCrypto.kdf1(chainB, responderEphemeralPub)
        chain = WireGuardCrypto.kdf1(chain, try dh(responderEphemeral, ephemeralPubIKey))
        chain = WireGuardCrypto.kdf1(chain, try dh(responderEphemeral, initiatorStaticKey))

        let psk = Data(repeating: 0, count: 32)
        let (chainC, tauKey, verifyKey) = WireGuardCrypto.kdf3(chain, psk)
        hash = WireGuardCrypto.hash(hash, tauKey)
        let emptyTag = try WireGuardCrypto.aeadSeal(
            SymmetricKey(data: verifyKey), counter: 0, plaintext: Data(), aad: hash)
        hash = WireGuardCrypto.hash(hash, emptyTag)

        let (respReceive, respSend) = WireGuardCrypto.kdf2(chainC, Data())

        var packet = Data([2, 0, 0, 0])
        packet += WireGuardHandshake.littleEndian(responderIndex)
        packet += WireGuardHandshake.littleEndian(initiation.localIndex)
        packet += Data(responderEphemeral.publicKey.rawRepresentation)
        packet += emptyTag
        packet += Data(repeating: 0, count: 32)
        return (packet, responderIndex, respReceive, respSend)
    }

    private func dh(_ key: Curve25519.KeyAgreement.PrivateKey,
                    _ peer: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        try key.sharedSecretFromKeyAgreement(with: peer)
            .withUnsafeBytes { Data($0) }
    }

    // MARK: - 传输会话与重放

    func testSessionRoundTripAndKeepalive() throws {
        let sendRaw = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let recvRaw = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let sessionA = WireGuardSession(send: SymmetricKey(data: sendRaw),
                                        receive: SymmetricKey(data: recvRaw),
                                        peerIndex: 7, localIndex: 9)
        let sessionB = WireGuardSession(send: SymmetricKey(data: recvRaw),
                                        receive: SymmetricKey(data: sendRaw),
                                        peerIndex: 9, localIndex: 7)

        let keepalive = try sessionA.sealPacket(Data())
        XCTAssertNil(try sessionB.openDatagram(keepalive))

        let payload = Data((0..<100).map { UInt8($0) })
        let wirePacket = try sessionA.sealPacket(payload)
        XCTAssertEqual(try sessionB.openDatagram(wirePacket), payload)
        XCTAssertNil(try sessionB.openDatagram(wirePacket))

        var tampered = wirePacket
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertThrowsError(try sessionB.openDatagram(tampered))
    }

    func testReplayWindowRejectsDuplicateAndOld() {
        var window = WireGuardReplayWindow()
        XCTAssertTrue(window.accept(1))
        XCTAssertTrue(window.accept(2))
        XCTAssertFalse(window.accept(2))
        XCTAssertTrue(window.accept(3000))
        XCTAssertFalse(window.accept(900))
        XCTAssertTrue(window.accept(953))
        XCTAssertFalse(window.accept(953))
    }
}
