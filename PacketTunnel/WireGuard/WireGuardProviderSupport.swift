import Foundation
import NetworkExtension
import SharedCore

/// PacketTunnelProvider 的 WireGuard（护盾线路）模式支撑。
/// 活动模式为 wireguard 时替代 Shadowsocks 引擎。
extension PacketTunnelProvider {

    func startWireGuardMode(
        diagnostics: TunnelDiagnosticsLogging?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            let store = try HudunTunnelConfigurationStore(
                appGroupID: SharedContainerSettings.appGroupID,
                keychainService: SharedContainerSettings.keychainService
            )
            let (configuration, privateKey) = try store.loadLaunchConfiguration()
            let flow = PacketTunnelFlowAdapter(packetFlow: packetFlow)
            let pump = try WireGuardTunnelPump(
                configuration: configuration,
                privateKeyBase64: privateKey,
                packetFlow: flow,
                diagnostics: diagnostics)
            applyWireGuardSettings(configuration) { [weak self] error in
                if let error {
                    self?.wgFail("tunnel settings failed", error, completionHandler)
                    return
                }
                self?.wireGuardPump = pump
                self?.startWireGuardPump(pump)
                completionHandler(nil)
            }
            scheduleHandshakeWatchdog(pump)
        } catch {
            wgFail("wg configuration unavailable", error, completionHandler)
        }
    }

    func stopWireGuardPump() {
        let pump = wireGuardPump
        wireGuardPump = nil
        Task { await MainActor.run { pump?.stop() } }
        pump?.stop()
    }

    // MARK: - 内部

    fileprivate func applyWireGuardSettings(
        _ configuration: HudunTunnelLaunchConfiguration,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: configuration.endpointHost)
        settings.ipv4Settings = NEIPv4Settings(
            addresses: [configuration.tunnelAddress],
            subnetMasks: ["255.255.255.255"])
        settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
        settings.mtu = NSNumber(value: configuration.mtu)
        let dnsSettings = NEDNSSettings(servers: configuration.dnsServers)
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings

        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    fileprivate func startWireGuardPump(_ pump: WireGuardTunnelPump) {
        pump.start()
    }

    /// 握手看门狗：8s 重试一次，25s 仍未成功则取消隧道并留痕。
    fileprivate func scheduleHandshakeWatchdog(_ pump: WireGuardTunnelPump) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self, weak pump] in
            guard let pump, !(pump.handshakeSucceeded) else { return }
            self?.diagnostics?("WG handshake retry")
            pump.retryHandshake()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) { [weak self, weak pump] in
            guard let pump, !(pump.handshakeSucceeded) else { return }
            let error = WireGuardError.badPacket("握手超时（25s）")
            self?.diagnostics?("WG fatal: 握手超时")
            self?.persistRuntimeFailureDetail(error)
            self?.cancelTunnelWithError(error)
        }
    }

    fileprivate func wgFail(
        _ prefix: String, _ error: Error,
        _ completionHandler: @escaping (Error?) -> Void
    ) {
        diagnostics?(("\(prefix): \(error.localizedDescription)"))
        persistRuntimeFailureDetail(error)
        NSLog("PacketTunnel %@: %@", prefix, error.localizedDescription)
        completionHandler(error)
    }
}
