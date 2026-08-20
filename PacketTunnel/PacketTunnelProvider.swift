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
        } catch {
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
