import Foundation
import NetworkExtension
import SharedCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let upstreamDNSServers = ["223.5.5.5", "119.29.29.29"]
    private var engine: TunnelEngine?
    var wireGuardPump: WireGuardTunnelPump?
    private var runtimeStatusStore: TunnelRuntimeStatusStore?
    var diagnostics: TunnelDiagnosticsLogging?

    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // 诊断设施最先就绪：配置加载失败也要在共享容器里留痕，
        // 否则扩展起不来时 App 侧看不到任何日志
        let diagnosticsStore = try? TunnelDiagnosticsStore(
            appGroupID: SharedContainerSettings.appGroupID
        )
        let diagnostics: TunnelDiagnosticsLogging? = diagnosticsStore.map { store in
            { message in store.append(message) }
        }
        self.diagnostics = diagnostics

        if activeModeIsWireGuard() {
            startWireGuardMode(diagnostics: diagnostics, completionHandler: completionHandler)
            return
        }

        do {
            runtimeStatusStore = try TunnelRuntimeStatusStore(
                appGroupID: SharedContainerSettings.appGroupID
            )
            runtimeStatusStore?.clearLastFailureDetail()

            let launchConfiguration = try TunnelConfigurationStore(
                appGroupID: SharedContainerSettings.appGroupID,
                keychainService: SharedContainerSettings.keychainService
            ).loadLaunchConfiguration()
            let routingConfiguration = try loadRoutingConfiguration()
            diagnostics?(
                "tunnel start bypassCN=\(routingConfiguration.bypassCNIP)"
            )
            let dnsCache = DNSCache(now: Date.init)
            let routeMatcher = RouteMatcher(
                configuration: routingConfiguration,
                cnIPRanges: try loadCNIPRanges()
            )
            let tunnelPacketFlow = PacketTunnelFlowAdapter(packetFlow: packetFlow)
            let packetWriter = TunnelPacketWriter(packetFlow: tunnelPacketFlow)
            let dnsCoordinator = DNSCoordinator(
                cache: dnsCache,
                whitelist: routingConfiguration.domainWhitelist,
                upstreamClient: ProxyDNSUpstreamClient(
                    config: launchConfiguration.connection
                ),
                localUpstreamClient: LocalDNSUpstreamClient(),
                matcher: routeMatcher,
                packetWriter: packetWriter,
                diagnostics: diagnostics
            )
            let tcpRouter = TCPRouter(
                launchConfiguration: launchConfiguration,
                matcher: routeMatcher,
                packetWriter: packetWriter,
                hostResolver: { [dnsCache] ip in dnsCache.lookupDomain(forAddress: ip) },
                diagnostics: diagnostics
            )
            let udpRouter = UDPRouter(
                launchConfiguration: launchConfiguration,
                matcher: routeMatcher,
                packetWriter: packetWriter,
                hostResolver: { [dnsCache] ip in dnsCache.lookupDomain(forAddress: ip) },
                diagnostics: diagnostics
            )
            let engine = TunnelEngine(
                dnsCoordinator: dnsCoordinator,
                tcpRouter: tcpRouter,
                udpRouter: udpRouter,
                packetFlow: tunnelPacketFlow,
                packetWriter: packetWriter,
                diagnostics: diagnostics
            )
            self.engine = engine
            Task {
                await engine.warmUpDNSCache()
            }
        } catch {
            diagnostics?("tunnel start failed: \(error.localizedDescription)")
            persistRuntimeFailureDetail(error)
            NSLog("PacketTunnel startTunnel failed while loading configuration: %@", error.localizedDescription)
            completionHandler(error)
            return
        }

        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: "127.0.0.1"
        )
        settings.ipv4Settings = NEIPv4Settings(
            addresses: ["10.0.0.2"],
            subnetMasks: ["255.255.255.0"]
        )
        settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
        settings.mtu = 1500 as NSNumber

        let dnsSettings = NEDNSSettings(servers: Self.upstreamDNSServers)
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings

        setTunnelNetworkSettings(settings) { error in
            if let error {
                self.diagnostics?("tunnel settings failed: \(error.localizedDescription)")
                self.persistRuntimeFailureDetail(error)
                NSLog("PacketTunnel setTunnelNetworkSettings failed: %@", error.localizedDescription)
                completionHandler(error)
                return
            }

            self.startEngine()

            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        diagnostics?("tunnel stop reason=\(reason.rawValue)")
        let engine = self.engine
        self.engine = nil
        let pump = wireGuardPump
        wireGuardPump = nil

        Task {
            await engine?.stop()
            pump?.stop()
            completionHandler()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        let engine = self.engine
        let pump = wireGuardPump
        Task {
            await engine?.stop()
            pump?.stop()
            completionHandler()
        }
    }

    override func wake() {
        stopWireGuardPump()
        if activeModeIsWireGuard() {
            startWireGuardMode(diagnostics: diagnostics) { _ in }
            return
        }
        startEngine()
    }

    private func startEngine() {
        engine?.start { [weak self] error in
            self?.persistRuntimeFailureDetail(error)
            self?.cancelTunnelWithError(error)
        }
    }

    /// 活动模式标记：缺省视为 Shadowsocks（兼容旧配置）。
    private func activeModeIsWireGuard() -> Bool {
        guard let store = try? HudunTunnelConfigurationStore(
            appGroupID: SharedContainerSettings.appGroupID,
            keychainService: SharedContainerSettings.keychainService) else {
            return false
        }
        return store.loadMode() == .wireguard
    }

    func persistRuntimeFailureDetail(_ error: Error) {
        runtimeStatusStore?.saveLastFailureDetail(error.localizedDescription)
    }

    private func loadRoutingConfiguration() throws -> RoutingConfiguration {
        try RoutingConfigurationStore(
            appGroupID: SharedContainerSettings.appGroupID
        ).load()
    }

    private func loadCNIPRanges() throws -> CNIPRangeList {
        if let ranges = loadDownloadedCNIPRanges() {
            return ranges
        }
        return loadBundledCNIPRanges()
    }

    private func loadDownloadedCNIPRanges() -> CNIPRangeList? {
        let store = try? CNIPListStore(appGroupID: SharedContainerSettings.appGroupID)
        guard let content = try? store?.load() else {
            return nil
        }
        return try? CNIPRangeList(textContent: content)
    }

    private func loadBundledCNIPRanges() -> CNIPRangeList {
        guard let url = Bundle.main.url(forResource: "china-ip-list", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8),
              let ranges = try? CNIPRangeList(textContent: content) else {
            return try! CNIPRangeList(ranges: [])
        }
        return ranges
    }
}
