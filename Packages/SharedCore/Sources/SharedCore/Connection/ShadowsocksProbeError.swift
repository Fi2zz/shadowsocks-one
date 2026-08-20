import Foundation

enum ShadowsocksProbeError: LocalizedError {
    case invalidPort
    case invalidResponse
    case connectionClosed
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "Shadowsocks 服务端口无效。"
        case .invalidResponse:
            "Shadowsocks 探测响应无效。"
        case .connectionClosed:
            "Shadowsocks 连接已关闭。"
        case .timeout:
            "Shadowsocks 连接超时。"
        }
    }
}
