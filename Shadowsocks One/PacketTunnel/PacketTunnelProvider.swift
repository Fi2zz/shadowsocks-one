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
            let tunnelPacketFlow = PacketTunnelFlowAdapter(packetFlow: packetFlow)
            let packetWriter = TunnelPacketWriter(packetFlow: tunnelPacketFlow)
            let dnsCoordinator = DNSCoordinator(
                cache: dnsCache,
                whitelist: routingConfiguration.domainWhitelist,
                upstreamClient: ProviderDNSUpstreamClient(provider: self),
                packetWriter: packetWriter
            )
            let tcpRouter = TCPRouter(
                launchConfiguration: launchConfiguration,
                matcher: routeMatcher,
                packetWriter: packetWriter
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

enum DNSUpstreamQueryError: Error, Equatable {
    case providerUnavailable
    case emptyResponse
}

private final class ProviderDNSUpstreamClient: DNSPayloadQuerying {
    private weak var provider: NEPacketTunnelProvider?

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
    }

    func query(serverIP: String, payload: Data) async throws -> Data {
        guard let provider else {
            throw DNSUpstreamQueryError.providerUnavailable
        }

        let session = provider.createUDPSession(
            to: NWHostEndpoint(hostname: serverIP, port: "53"),
            from: nil
        )
        let gate = ContinuationGate()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.setReadHandler({ datagrams, error in
                    if let error {
                        gate.resume(continuation, result: .failure(error))
                        return
                    }

                    guard let response = datagrams?.first else {
                        gate.resume(
                            continuation,
                            result: .failure(DNSUpstreamQueryError.emptyResponse)
                        )
                        return
                    }

                    gate.resume(continuation, result: .success(response as Data))
                }, maxDatagrams: 1)

                session.writeDatagram(payload) { error in
                    if let error {
                        gate.resume(continuation, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            session.cancel()
        }
    }
}

private final class ContinuationGate {
    private let lock = NSLock()
    private var finished = false

    func resume(
        _ continuation: CheckedContinuation<Data, Error>,
        result: Result<Data, Error>
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        continuation.resume(with: result)
    }
}
