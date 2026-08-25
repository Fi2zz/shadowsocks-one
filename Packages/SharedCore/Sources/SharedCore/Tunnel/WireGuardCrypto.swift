import Foundation
import CryptoKit

/// WireGuard 白皮书定义的哈希/MAC/KDF 原语（BLAKE2s 体系）。
enum WireGuardCrypto {
    static let construction = "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s"
    static let identifier = "WireGuard v1 zx2c4 Jason@zx2c4.com"
    static let labelMac1 = "mac1----"

    /// HASH：BLAKE2s-256 单次摘要（支持多段拼接）。
    static func hash(_ parts: Data...) -> Data {
        var input = [UInt8]()
        for part in parts { input.append(contentsOf: [UInt8](part)) }
        return Data(Blake2s().hash(input))
    }

    /// KEYEDMAC：BLAKE2s 内建 keying（MAC1 用，16 字节输出）。
    static func keyedMac(_ key: Data, _ data: Data, length: Int = 32) -> Data {
        Data(Blake2s(digestLength: length, key: [UInt8](key)).hash([UInt8](data)))
    }

    /// HMAC-BLAKE2s（标准构造，块长 64）。
    static func hmac(_ key: Data, _ data: Data) -> Data {
        var k = [UInt8](key)
        if k.count > Self.blockSize { k = [UInt8](hash(Data(k))) }
        k.append(contentsOf: [UInt8](repeating: 0, count: Self.blockSize - k.count))
        let ipad = k.map { $0 ^ 0x36 }
        let opad = k.map { $0 ^ 0x5c }
        let inner = hash(Data(ipad) + data)
        return hash(Data(opad) + inner)
    }

    private static let blockSize = 64

    /// KDF_n（对齐 wireguard-go）：t = HMAC(ck, ikm)；
    /// o1 = HMAC(t, 0x1)；o2 = HMAC(t, o1‖0x2)；o3 = HMAC(t, o1‖0x3)。
    static func kdf1(_ chainingKey: Data, _ ikm: Data) -> Data {
        let t = hmac(chainingKey, ikm)
        return hmac(t, Data([0x01]))
    }

    static func kdf2(_ chainingKey: Data, _ ikm: Data) -> (Data, Data) {
        let t = hmac(chainingKey, ikm)
        let o1 = hmac(t, Data([0x01]))
        let o2 = hmac(t, o1 + Data([0x02]))
        return (o1, o2)
    }

    static func kdf3(_ chainingKey: Data, _ ikm: Data) -> (Data, Data, Data) {
        let t = hmac(chainingKey, ikm)
        let o1 = hmac(t, Data([0x01]))
        let o2 = hmac(t, o1 + Data([0x02]))
        let o3 = hmac(t, o1 + Data([0x03]))
        return (o1, o2, o3)
    }

    /// ChaChaPoly nonce：4 字节零 ‖ counter 小端。
    static func nonce(counter: UInt64) throws -> ChaChaPoly.Nonce {
        var value = counter.littleEndian
        let tail = withUnsafeBytes(of: &value) { Data($0) }
        return try ChaChaPoly.Nonce(data: Data([0, 0, 0, 0]) + tail)
    }

    static func aeadSeal(_ key: SymmetricKey, counter: UInt64,
                         plaintext: Data, aad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext, using: key, nonce: nonce(counter: counter), authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func aeadOpen(_ key: SymmetricKey, counter: UInt64,
                         combined: Data, aad: Data) throws -> Data {
        guard combined.count >= 16 else {
            throw WireGuardError.badPacket("密文长度非法 \(combined.count)")
        }
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce(counter: counter),
            ciphertext: combined.dropLast(16),
            tag: combined.suffix(16))
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }

    /// 调试摘要：前 8 字节 hex。
    static func hexPrefix(_ data: Data) -> String {
        data.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// TAI64N 时间戳（64 位秒大端 + 32 位纳秒大端），防重放需单调递增。
    static func tai64n(now: Date = Date()) -> Data {
        let seconds = UInt64(now.timeIntervalSince1970) &+ 0x400000000000000a
        let micros = UInt32(((now.timeIntervalSince1970
            - now.timeIntervalSince1970.rounded(.down)) * 1_000_000).rounded())
        let nanos = micros &* 1000
        var out = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: seconds >> shift))
        }
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: nanos >> shift))
        }
        return out
    }
}

public enum WireGuardError: Error, LocalizedError {
    case badPacket(String)
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .badPacket(let detail): return "WireGuard 包异常：\(detail)"
        case .authenticationFailed: return "WireGuard 校验失败"
        }
    }
}
