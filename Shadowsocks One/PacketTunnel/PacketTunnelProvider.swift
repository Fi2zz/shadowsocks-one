import Foundation
import NetworkExtension
import SharedCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
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
            let dnsCoordinator = DNSCoordinator(
                cache: dnsCache,
                whitelist: routingConfiguration.domainWhitelist
            )
            let tcpRouter = TCPRouter(
                launchConfiguration: launchConfiguration,
                matcher: routeMatcher
            )
            let engine = TunnelEngine(
                dnsCoordinator: dnsCoordinator,
                tcpRouter: tcpRouter,
                packetFlow: PacketTunnelFlowAdapter(packetFlow: packetFlow)
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

        setTunnelNetworkSettings(settings) { error in
            if let error {
                self.persistRuntimeFailureDetail(error)
                NSLog("PacketTunnel setTunnelNetworkSettings failed: %@", error.localizedDescription)
                completionHandler(error)
                return
            }

            self.engine?.start { [weak self] error in
                self?.persistRuntimeFailureDetail(error)
                self?.cancelTunnelWithError(error)
            }

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

    private func persistRuntimeFailureDetail(_ error: Error) {
        runtimeStatusStore?.saveLastFailureDetail(error.localizedDescription)
    }

    private func loadRoutingConfiguration() throws -> RoutingConfiguration {
        try RoutingConfigurationStore(
            appGroupID: SharedContainerSettings.appGroupID
        ).load()
    }

    private func loadCNIPRanges() throws -> CNIPRangeList {
        try CNIPRangeList(ranges: [])
    }
}
