import Foundation
import NetworkExtension
import SharedCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let upstreamDNSServers = ["223.5.5.5", "119.29.29.29"]
    private var engine: TunnelEngine?
    private var runtimeStatusStore: TunnelRuntimeStatusStore?

    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // #region debug-point E:start-tunnel-entry
        TunnelDebugReporter.send(
            "E",
            location: "PacketTunnelProvider.startTunnel",
            message: "startTunnel invoked"
        )
        // #endregion
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
                packetWriter: packetWriter
            )
            let tcpRouter = TCPRouter(
                launchConfiguration: launchConfiguration,
                matcher: routeMatcher,
                packetWriter: packetWriter,
                hostResolver: { [dnsCache] ip in dnsCache.lookupDomain(forAddress: ip) }
            )
            let engine = TunnelEngine(
                dnsCoordinator: dnsCoordinator,
                tcpRouter: tcpRouter,
                packetFlow: tunnelPacketFlow,
                packetWriter: packetWriter
            )
            self.engine = engine
            Task {
                await engine.warmUpDNSCache()
            }
            // #region debug-point A:configuration-loaded
            TunnelDebugReporter.send(
                "A",
                location: "PacketTunnelProvider.startTunnel",
                message: "tunnel configuration loaded",
                data: [
                    "whitelistCount": routingConfiguration.domainWhitelist.count,
                    "serverHost": launchConfiguration.connection.host,
                    "serverPort": launchConfiguration.connection.port,
                ]
            )
            // #endregion
        } catch {
            persistRuntimeFailureDetail(error)
            NSLog("PacketTunnel startTunnel failed while loading configuration: %@", error.localizedDescription)
            // #region debug-point E:start-tunnel-load-failed
            TunnelDebugReporter.send(
                "E",
                location: "PacketTunnelProvider.startTunnel",
                message: "configuration load failed",
                data: ["error": error.localizedDescription]
            )
            // #endregion
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
                self.persistRuntimeFailureDetail(error)
                NSLog("PacketTunnel setTunnelNetworkSettings failed: %@", error.localizedDescription)
                // #region debug-point E:settings-failed
                TunnelDebugReporter.send(
                    "E",
                    location: "PacketTunnelProvider.setTunnelNetworkSettings",
                    message: "network settings failed",
                    data: ["error": error.localizedDescription]
                )
                // #endregion
                completionHandler(error)
                return
            }

            // #region debug-point A:settings-ready
            TunnelDebugReporter.send(
                "A",
                location: "PacketTunnelProvider.setTunnelNetworkSettings",
                message: "network settings applied and engine starting"
            )
            // #endregion
            self.startEngine()

            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        // #region debug-point E:stop-tunnel
        TunnelDebugReporter.send(
            "E",
            location: "PacketTunnelProvider.stopTunnel",
            message: "stopTunnel invoked",
            data: ["reason": reason.rawValue]
        )
        // #endregion
        let engine = self.engine
        self.engine = nil

        Task {
            await engine?.stop()
            completionHandler()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        Task {
            await engine?.stop()
            completionHandler()
        }
    }

    override func wake() {
        startEngine()
    }

    private func startEngine() {
        engine?.start { [weak self] error in
            self?.persistRuntimeFailureDetail(error)
            // #region debug-point E:engine-fatal
            TunnelDebugReporter.send(
                "E",
                location: "PacketTunnelProvider.engineFatal",
                message: "engine reported fatal error",
                data: ["error": error.localizedDescription]
            )
            // #endregion
            self?.cancelTunnelWithError(error)
        }
    }

    private func persistRuntimeFailureDetail(_ error: Error) {
        runtimeStatusStore?.saveLastFailureDetail(error.localizedDescription)
    }

    private func loadRoutingConfiguration() throws -> RoutingConfiguration {
        try RoutingConfigurationStore(
            appGroupID: SharedContainerSettings.appGroupID
        ).load()
    }

    private func loadCNIPRanges() throws -> CNIPRangeList {
        guard let url = Bundle.main.url(forResource: "china-ip-list", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return try CNIPRangeList(ranges: [])
        }

        let ranges = content.split(whereSeparator: \.isNewline).map(String.init)
        return try CNIPRangeList(ranges: ranges)
    }
}
