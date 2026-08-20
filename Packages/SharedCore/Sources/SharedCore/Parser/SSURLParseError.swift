import Foundation

public enum SSURLParseError: Error, Equatable, Sendable {
    case invalidScheme
    case malformedURL
    case missingHost
    case missingPort
    case invalidPort
    case invalidUserInfo
    case unsupportedCipher(String)
    case invalidBase64
    case emptyPassword
}

extension SSURLParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidScheme:
            return "仅支持 ss:// 协议。"
        case .malformedURL:
            return "节点链接格式不正确。"
        case .missingHost:
            return "节点缺少 host。"
        case .missingPort:
            return "节点缺少 port。"
        case .invalidPort:
            return "节点 port 无效。"
        case .invalidUserInfo:
            return "节点用户信息解析失败。"
        case let .unsupportedCipher(cipher):
            return "当前版本暂不支持 \(cipher)。"
        case .invalidBase64:
            return "节点 Base64 内容无效。"
        case .emptyPassword:
            return "节点 password 不能为空。"
        }
    }
}
