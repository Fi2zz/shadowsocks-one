import Foundation

enum ShadowsocksCryptoError: LocalizedError {
    case unsupportedPayloadLength
    case invalidCiphertext
    case randomBytesFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedPayloadLength:
            "Shadowsocks 数据块长度无效。"
        case .invalidCiphertext:
            "Shadowsocks 密文校验失败。"
        case .randomBytesFailed:
            "无法生成随机 salt。"
        }
    }
}
