// HudunCryptoTests.swift — docs/hudun_master_doc.md §6.1 固定向量（离线，必须全绿）
import XCTest
import CryptoKit
@testable import ShadowsocksOne

final class HudunCryptoTests: XCTestCase {

    // MARK: - V1 签名（排序拼接 + 盐）
    // 独立参照实现: md5("a=1b=2ts=1700000000" + salt) = 751f0b62ec734539f898f5cc2b25456c
    func testGenerateSignVector() {
        let sign = HudunClient.generateSign(["b": "2", "a": "1"],
                                            ts: "1700000000",
                                            salt: "WOYqZGTomCWAFREVnyxiyou")
        XCTAssertEqual(sign, "751f0b62ec734539f898f5cc2b25456c")
    }

    /// route_info 实际形状：id < is_full_route < public_key < ts 的字典序，
    /// 且 ts 参与签名。此向量锁定排序规则防回归。
    func testGenerateSignRouteInfoShape() {
        let p = ["id": "19", "public_key": "abc+/=", "is_full_route": "true"]
        let sign = HudunClient.generateSign(p, ts: "1700000000", salt: "SALT")
        // 参照: md5("id=19is_full_route=truepublic_key=abc+/=ts=1700000000" + "SALT")
        let expect = HudunCrypto.md5Hex(
            "id=19is_full_route=truepublic_key=abc+/=ts=1700000000" + "SALT")
        XCTAssertEqual(sign, expect)
        XCTAssertFalse(sign.isEmpty)
    }

    // MARK: - V3 X25519 + SHA256 KDF（CryptoKit ↔ PyNaCl 双库一致）
    func testX25519KDFVector() throws {
        let privHex = "a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00"
        let remoteHex = "b3a0a0b31f7acd579d6e5882b1b1be1e48acefa90ffc2a9b6ecde398af49e924"
        let priv = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: HudunCrypto.hexDecode(privHex))
        let peer = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: HudunCrypto.hexDecode(remoteHex))
        let shared = try priv.sharedSecretFromKeyAgreement(with: peer)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        XCTAssertEqual(HudunCrypto.hexEncode(sharedBytes),
            "47851523f75cf3e763a67dbca4a0f35d62cc2c3e695968350fbe0b3a278aab53")
        XCTAssertEqual(HudunCrypto.hexEncode(Data(SHA256.hash(data: sharedBytes))),
            "7e1a8b66ba806e5b66bb7e608286e5256991c5ef30d11fac5197b20bfbfe259d")
    }

    // MARK: - V4 AES-256-CBC 解密向量（PyNaCl 加密 → Swift 解密）
    func testAesCbcDecryptVector() throws {
        let key = HudunCrypto.hexDecode(
            "7e1a8b66ba806e5b66bb7e608286e5256991c5ef30d11fac5197b20bfbfe259d")
        let blob = Data(base64Encoded:
            "AAECAwQFBgcICQoLDA0OD4wXFw/zA8+YX1mGb2V+Fmngt8m7UVHuHN/sSTjSaBdseHb/zRMN98ZtpGsqFU5p8Q==")!
        let plain = try HudunCrypto.aesCbcDecrypt(blob, key: key)
        XCTAssertEqual(String(data: plain, encoding: .utf8),
                       #"{"code":200,"msg":"","data":{"ok":true}}"#)
    }

    func testAesCbcDecryptRejectsBadLength() {
        XCTAssertThrowsError(try HudunCrypto.aesCbcDecrypt(Data([0, 1, 2]), key: Data(repeating: 7, count: 32)))
    }

    // MARK: - hex 编解码（回归保护：曾出现半字节流 bug）
    func testHexDecodeRoundTrip() {
        let hex = "b3a0a0b31f7acd579d6e5882b1b1be1e48acefa90ffc2a9b6ecde398af49e924"
        let data = HudunCrypto.hexDecode(hex)
        XCTAssertEqual(data.count, 32)                       // 曾退化为 16/64 字节
        XCTAssertEqual(HudunCrypto.hexEncode(data), hex)
    }

    func testHexDecodeUppercaseAndOddLength() {
        XCTAssertEqual(HudunCrypto.hexDecode("ABCD").count, 2)
        XCTAssertEqual(HudunCrypto.hexDecode("ABC").count, 1)   // 尾部残缺安全截断
    }

    // MARK: - URL 编码（字典序 + 保留字符转义）
    func testUrlEncodeSortedAndEscaped() {
        let out = HudunClient.urlEncode(["public_key": "ab+/=", "id": "4"])
        XCTAssertEqual(out, "id=4&public_key=ab%2B%2F%3D")
    }

    // MARK: - JWT exp 解析（V5 向量）
    func testJwtExpiry() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
                + "eyJleHAiOjE3ODc1NTAzNjIsImlzcyI6IndpcmVndWFyZCJ9."
                + "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
        XCTAssertEqual(HudunClient.jwtExpiry(jwt),
                       Date(timeIntervalSince1970: 1_787_550_362))
        XCTAssertNil(HudunClient.jwtExpiry("not.a.jwt"))
    }
}
