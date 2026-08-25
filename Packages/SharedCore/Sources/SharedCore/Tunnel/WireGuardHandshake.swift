import Foundation
import CryptoKit

/// Noise_IKpsk2 发起方握手（WireGuard 白皮书 §5.4，无 PSK 变体）。
public enum WireGuardHandshake {
    public struct Initiation {
        public let packet: Data
        public let localIndex: UInt32
        let chainKey: Data
        let hash: Data
        let ephemeralPrivate: Curve25519.KeyAgreement.PrivateKey
    }

    public struct TransportKeys {
        public let send: SymmetricKey
        public let receive: SymmetricKey
        public let peerIndex: UInt32
        public let localIndex: UInt32
    }

    /// 构造 148 字节 handshake initiation（含 MAC1；MAC2 置零）。
    public static func createInitiation(
        staticPrivate: Curve25519.KeyAgreement.PrivateKey,
        peerStaticPublic: Curve25519.KeyAgreement.PublicKey
    ) throws -> Initiation {
        let localIndex = UInt32.random(in: 1...UInt32.max)
        var chain = Self.hash(Data(WireGuardCrypto.construction.utf8))
        var hash = Self.hash(chain, Data(WireGuardCrypto.identifier.utf8))
        let peerPub = Data(peerStaticPublic.rawRepresentation)
        hash = Self.hash(hash, peerPub)

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPub = Data(ephemeral.publicKey.rawRepresentation)
        hash = Self.hash(hash, ephemeralPub)
        chain = WireGuardCrypto.kdf1(chain, ephemeralPub)

        let initiatorPub = Data(staticPrivate.publicKey.rawRepresentation)
        let (chainA, keyA) = WireGuardCrypto.kdf2(chain, shared(ephemeral, peerStaticPublic))
        let encryptedStatic = try WireGuardCrypto.aeadSeal(
            SymmetricKey(data: keyA), counter: 0, plaintext: initiatorPub, aad: hash)
        hash = Self.hash(hash, encryptedStatic)

        let (chainB, keyB) = WireGuardCrypto.kdf2(chainA, shared(staticPrivate, peerStaticPublic))
        let encryptedTimestamp = try WireGuardCrypto.aeadSeal(
            SymmetricKey(data: keyB), counter: 0,
            plaintext: WireGuardCrypto.tai64n(), aad: hash)
        hash = Self.hash(hash, encryptedTimestamp)

        var packet = Data([1, 0, 0, 0])
        packet += littleEndian(localIndex)
        packet += ephemeralPub
        packet += encryptedStatic
        packet += encryptedTimestamp
        let macKey = Self.hash(Data(WireGuardCrypto.labelMac1.utf8), peerPub)
        packet += WireGuardCrypto.keyedMac(macKey, packet, length: 16)
        packet += Data(repeating: 0, count: 16)

        return Initiation(packet: packet, localIndex: localIndex,
                          chainKey: chainB, hash: hash, ephemeralPrivate: ephemeral)
    }

    /// 解析 92 字节 response 并派生传输密钥（se = 本端静态 × 对端临时）。
    @discardableResult
    public static func processResponse(
        _ data: Data, initiation: Initiation,
        staticPrivate: Curve25519.KeyAgreement.PrivateKey
    ) throws -> TransportKeys {
        guard data.count == 92, data[data.startIndex] == 2 else {
            throw WireGuardError.badPacket("响应长度/类型非法 \(data.count)")
        }
        guard readUInt32LE(data, 8) == initiation.localIndex else {
            throw WireGuardError.badPacket("响应索引不匹配")
        }
        let peerIndex = readUInt32LE(data, 4)
        let responderEphemeralPub = data.subdata(in: 12..<44)
        let responderEphemeral = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: responderEphemeralPub)

        var hash = Self.hash(initiation.hash, responderEphemeralPub)
        var chain = WireGuardCrypto.kdf1(initiation.chainKey, responderEphemeralPub)
        chain = WireGuardCrypto.kdf1(
            chain, shared(initiation.ephemeralPrivate, responderEphemeral))
        chain = WireGuardCrypto.kdf1(
            chain, shared(staticPrivate, responderEphemeral))

        let psk = Data(repeating: 0, count: 32)
        let (chainC, tau, verifyKey) = WireGuardCrypto.kdf3(chain, psk)
        hash = Self.hash(hash, tau)
        do {
            _ = try WireGuardCrypto.aeadOpen(
                SymmetricKey(data: verifyKey), counter: 0,
                combined: data.subdata(in: 44..<60), aad: hash)
        } catch {
            throw WireGuardError.authenticationFailed
        }
        chain = chainC
        hash = Self.hash(hash, data.subdata(in: 44..<60))

        let (send, receive) = WireGuardCrypto.kdf2(chain, Data())
        return TransportKeys(send: SymmetricKey(data: send),
                             receive: SymmetricKey(data: receive),
                             peerIndex: peerIndex, localIndex: initiation.localIndex)
    }

    // MARK: - 工具

    private static func shared(_ private_: Curve25519.KeyAgreement.PrivateKey,
                               _ public_: Curve25519.KeyAgreement.PublicKey) -> Data {
        (try? private_.sharedSecretFromKeyAgreement(with: public_)
            .withUnsafeBytes { Data($0) }) ?? Data()
    }

    static func hash(_ a: Data, _ b: Data = Data()) -> Data {
        WireGuardCrypto.hash(a, b)
    }

    static func littleEndian(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        let b = [UInt8](data.subdata(in: offset..<(offset + 4)))
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }
}
