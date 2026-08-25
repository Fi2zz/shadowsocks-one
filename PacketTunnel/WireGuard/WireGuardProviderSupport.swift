import Foundation
import NetworkExtension
import SharedCore

/// PacketTunnelProvider 的 WireGuard（护盾线路）模式支撑。
/// 复用 SS 模式的分流设施（RouteMatcher/DNSCoordinator/CN 库），
/// 仅将代理出口替换为 WG 注入（TCP 迷你栈 / UDP 封包 / DNS over WG）。
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
            let writer = TunnelPacketWriter(packetFlow: flow)

            let egress = WGProxiedEgress(tunnelAddress: configuration.tunnelAddress)
            let pump = try WireGuardTunnelPump(
                configuration: configuration,
                privateKeyBase64: privateKey,
                packetFlow: flow,
                egress: egress,
                diagnostics: diagnostics)
            egress.attachPacketWriter(writer)

            let routing = try loadRoutingConfiguration()
            let matcher = RouteMatcher(
                configuration: routing,
                cnIPRanges: try loadCNIPRanges())
            let engine = buildWGSplitEngine(
                egress: egress,
                matcher: matcher,
                writer: writer,
                whitelist: routing.domainWhitelist,
                tunnelAddress: configuration.tunnelAddress,
                diagnostics: diagnostics)
            self.wireGuardEngine = engine

            applyWireGuardSettings(configuration) { [weak self] error in
                if let error {
                    self?.wgFail("tunnel settings failed", error, completionHandler)
                    return
                }
                self?.wireGuardPump = pump
                self?.wireGuardEngine = engine
                pump.start()
                Task { await engine.warmUpDNSCache() }
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
        let engine = wireGuardEngine
        wireGuardEngine = nil
        Task {
            await engine?.stop()
            pump?.stop()
        }
    }

    // MARK: - 分流引擎组装

    /// 与 SS 引擎同构：DNS 协调器 + TCP/UDP 路由器，代理出口全部换成 WG 适配器。
    private func buildWGSplitEngine(
        egress: WGProxiedEgress,
        matcher: RouteMatcher,
        writer: TunnelPacketWriter,
        whitelist: [String],
        tunnelAddress: String,
        diagnostics: TunnelDiagnosticsLogging?
    ) -> TunnelEngine {
        let dnsCache = DNSCache(now: Date.init)
        let wgDNS = WGDNSUpstreamClient(
            egress: egress, tunnelAddress: tunnelAddress)
        let dnsCoordinator = DNSCoordinator(
            cache: dnsCache,
            whitelist: whitelist,
            upstreamClient: wgDNS,
            localUpstreamClient: LocalDNSUpstreamClient(),
            matcher: matcher,
            packetWriter: writer,
            diagnostics: diagnostics)

        let placeholderConfig = Self.placeholderLaunchConfiguration()
        let tcpRouter = TCPRouter(
            launchConfiguration: placeholderConfig,
            matcher: matcher,
            packetWriter: writer,
            directRelayFactory: { key in
                try DirectTCPRelay(
                    host: key.destinationAddress,
                    port: key.destinationPort,
                    diagnostics: diagnostics)
            },
            proxyRelayFactory: { key in
                WGTCPProxyRelay(
                    egress: egress,
                    tunnelAddress: tunnelAddress,
                    destinationHost: key.destinationAddress,
                    destinationPort: key.destinationPort,
                    diagnostics: diagnostics)
            },
            hostResolver: { [dnsCache] ip in dnsCache.lookupDomain(forAddress: ip) },
            diagnostics: diagnostics)

        let udpRouter = UDPRouter(
            launchConfiguration: placeholderConfig,
            matcher: matcher,
            packetWriter: writer,
            directRelayFactory: { key in
                try DirectUDPRelay(
                    host: key.destinationAddress,
                    port: key.destinationPort)
            },
            proxyRelayFactory: { key in
                WGUDPFlowRelay(
                    egress: egress,
                    tunnelAddress: tunnelAddress,
                    destinationHost: key.destinationAddress,
                    destinationPort: key.destinationPort)
            },
            hostResolver: { [dnsCache] ip in dnsCache.lookupDomain(forAddress: ip) },
            diagnostics: diagnostics)

        return TunnelEngine(
            dnsCoordinator: dnsCoordinator,
            tcpRouter: tcpRouter,
            udpRouter: udpRouter,
            packetFlow: PacketTunnelFlowAdapter(packetFlow: self.packetFlow),
            packetWriter: writer,
            diagnostics: diagnostics)
    }

    /// 路由器工厂全量注入后，SS 配置仅作占位、不再被触碰。
    private static func placeholderLaunchConfiguration() -> TunnelLaunchConfiguration {
        TunnelLaunchConfiguration(
            profileID: UUID(),
            connection: ConnectionConfig(
                host: "placeholder.invalid", port: 1,
                method: .aes256GCM, password: "placeholder"),
            plugin: nil,
            pluginOptions: nil)
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
        let dnsSettings = NEDNSSettings(servers: ["223.5.5.5", "119.29.29.29"])
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
