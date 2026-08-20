import Foundation

public enum TunnelConfigurationError: Error, Equatable, Sendable {
    case missingConfiguration
    case missingPassword
    case unsupportedPlugin(String)
}

extension TunnelConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "共享 Tunnel 配置不存在。"
        case .missingPassword:
            return "共享 Tunnel 配置缺少密码。"
        case let .unsupportedPlugin(plugin):
            return "当前版本暂不支持 plugin 节点：\(plugin)"
        }
    }
}
