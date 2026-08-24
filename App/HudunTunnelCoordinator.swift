import Foundation
import SharedCore

/// 护盾线路 → 系统隧道激活协调：保存 WG 启动配置、切换模式并连接。
@MainActor
final class HudunTunnelCoordinator {
    private let controller: any TunnelControlling

    init(controller: any TunnelControlling) {
        self.controller = controller
    }

    /// 激活失败返回错误文案；成功返回 nil（连接状态由隧道状态流驱动）。
    func activate(_ wgConfig: HudunWGConfig,
                  lineID: Int, lineName: String) async -> String? {
        guard let launch = Self.launchConfiguration(
            from: wgConfig, lineID: lineID, lineName: lineName) else {
            return "WG 配置字段不完整（endpoint/密钥缺失）"
        }
        do {
            let store = try HudunTunnelConfigurationStore(
                appGroupID: SharedContainerSettings.appGroupID,
                keychainService: SharedContainerSettings.keychainService)
            try store.activate(launch, privateKeyBase64: wgConfig.privateKeyB64)
        } catch {
            return "保存隧道配置失败：\(error.localizedDescription)"
        }
        do {
            try await controller.connect()
        } catch {
            return "VPN 启动失败：\(error.localizedDescription)"
        }
        return nil
    }

    static func launchConfiguration(from wgConfig: HudunWGConfig,
                                    lineID: Int,
                                    lineName: String) -> HudunTunnelLaunchConfiguration? {
        guard let hostPort = parseEndpoint(wgConfig.endpoint),
              let peerData = Data(base64Encoded: wgConfig.peerPublicKey), !peerData.isEmpty else {
            return nil
        }
        return HudunTunnelLaunchConfiguration(
            endpointHost: hostPort.host,
            endpointPort: hostPort.port,
            peerPublicKeyBase64: wgConfig.peerPublicKey,
            tunnelAddress: wgConfig.address,
            dnsServers: wgConfig.dns.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) },
            mtu: UInt16(clamping: max(1280, wgConfig.mtu)),
            lineID: lineID,
            lineName: lineName,
            expiresAt: wgConfig.expiresAt)
    }

    private static func parseEndpoint(_ endpoint: String) -> (host: String, port: UInt16)? {
        guard let separator = endpoint.lastIndex(of: ":") else { return nil }
        let host = String(endpoint[..<separator])
        let port = UInt16(endpoint[endpoint.index(after: separator)...])
        guard !host.isEmpty, let port else { return nil }
        return (host, port)
    }
}
