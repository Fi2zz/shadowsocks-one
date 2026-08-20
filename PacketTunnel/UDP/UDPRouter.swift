import Darwin
import Foundation
import SharedCore

protocol UDPRouting: AnyObject {
    func route(_ packet: IPPacket) async throws
    func stopAll() async
    func setPacketWriter(_ packetWriter: (any TunnelPacketWriting)?)
}

enum UDPRouterError: Error, Equatable {
    case relayTimeout
}

final class UDPRouter: UDPRouting {
    private let matcher: RouteMatcher
    private let sessionStore: UDPSessionStore
    private let relayTimeoutNanoseconds: UInt64
    private let packetWriterLock = NSLock()
    private var packetWriter: (any TunnelPacketWriting)?
    private let directRelayFactory: RelayFactory
    private let proxyRelayFactory: RelayFactory
    private let hostResolver: HostResolver?
    private let diagnostics: TunnelDiagnosticsLogging?

    typealias RelayFactory = @Sendable (UDPFlowKey) throws -> any UDPFlowRelaying
    typealias HostResolver = @Sendable (String) -> String?

    init(
        launchConfiguration: TunnelLaunchConfiguration,
        matcher: RouteMatcher,
        sessionStore: UDPSessionStore = UDPSessionStore(),
        packetWriter: (any TunnelPacketWriting)? = nil,
        directRelayFactory: RelayFactory? = nil,
        proxyRelayFactory: RelayFactory? = nil,
        hostResolver: HostResolver? = nil,
        relayTimeoutNanoseconds: UInt64 = 5_000_000_000,
        diagnostics: TunnelDiagnosticsLogging? = nil
    ) {
        self.matcher = matcher
        self.sessionStore = sessionStore
        self.relayTimeoutNanoseconds = relayTimeoutNanoseconds
        self.packetWriter = packetWriter
        self.hostResolver = hostResolver
        self.diagnostics = diagnostics
        self.directRelayFactory = directRelayFactory ?? { key in
            try DirectUDPRelay(
                host: key.destinationAddress,
                port: key.destinationPort
            )
        }
        self.proxyRelayFactory = proxyRelayFactory ?? { key in
            try ShadowsocksUDPRelay(
                launchConfiguration: launchConfiguration,
                destinationHost: key.destinationAddress,
                destinationPort: key.destinationPort
            )
        }
    }

    func route(_ packet: IPPacket) async throws {
        let udp = try packet.udpSegment()
        let key = UDPFlowKey(packet: packet, udp: udp)
        let session = try makeSession(for: key, packet: packet)

        stopEvicted(session.evictedRelays)
        dispatch(udp.payload, through: session, key: key)
    }

    func stopAll() async {
        let relays = sessionStore.removeAllRelays()
        for relay in relays {
            await relay.stop()
        }
    }

    func setPacketWriter(_ packetWriter: (any TunnelPacketWriting)?) {
        packetWriterLock.lock()
        self.packetWriter = packetWriter
        packetWriterLock.unlock()
    }

    private func makeSession(
        for key: UDPFlowKey,
        packet: IPPacket
    ) throws -> UDPSessionStore.SessionResult {
        let resolvedHost = hostResolver?(packet.destinationAddress)
        let decision = matcher.route(forHost: resolvedHost, ipString: packet.destinationAddress)

        return try sessionStore.session(for: key) {
            self.diagnostics?(
                "UDP \(decision.rawValue) \(key.destinationAddress):\(key.destinationPort) host=\(resolvedHost ?? "-")"
            )
            let relay = try self.makeRelay(for: key, decision: decision)
            self.attachCallbacks(to: relay, for: key)
            return relay
        }
    }

    private func makeRelay(
        for key: UDPFlowKey,
        decision: RouteDecision
    ) throws -> any UDPFlowRelaying {
        switch decision {
        case .direct:
            return try directRelayFactory(key)
        case .proxy:
            return try proxyRelayFactory(key)
        }
    }

    private func attachCallbacks(to relay: any UDPFlowRelaying, for key: UDPFlowKey) {
        relay.onInboundDatagram = { [weak self] data in
            try? await self?.writeInboundDatagram(data, for: key)
        }
        relay.onClosed = { [weak self] in
            _ = self?.sessionStore.removeRelay(for: key)
        }
    }

    private func writeInboundDatagram(_ data: Data, for key: UDPFlowKey) throws {
        guard let packetWriter = currentPacketWriter() else {
            return
        }

        let packet = try UDPPacketBuilder.build(
            sourceIP: key.destinationAddress,
            sourcePort: key.destinationPort,
            destinationIP: key.sourceAddress,
            destinationPort: key.sourcePort,
            payload: data
        )
        packetWriter.write([packet], protocols: [NSNumber(value: AF_INET)])
    }

    /// UDP 尽力而为：relay 启动与发送不阻塞引擎读包循环，超时或失败即回收会话
    private func dispatch(
        _ payload: Data,
        through session: UDPSessionStore.SessionResult,
        key: UDPFlowKey
    ) {
        let timeout = relayTimeoutNanoseconds
        Task {
            do {
                try await withTimeout(nanoseconds: timeout) {
                    if session.sessionCreated {
                        try await session.relay.start()
                    }
                    try await session.relay.forwardOutboundPayload(payload)
                }
            } catch {
                let detail = "UDP drop \(key.destinationAddress):\(key.destinationPort): \(error.localizedDescription)"
                NSLog("UDPRouter dropped datagram after relay failure: %@", error.localizedDescription)
                diagnostics?(detail)
                await tearDownSession(for: key)
            }
        }
    }

    private func withTimeout(
        nanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw UDPRouterError.relayTimeout
            }
            defer { group.cancelAll() }
            try await group.next()!
        }
    }

    private func tearDownSession(for key: UDPFlowKey) async {
        let relay = sessionStore.removeRelay(for: key)
        await relay?.stop()
    }

    private func stopEvicted(_ relays: [any UDPFlowRelaying]) {
        for relay in relays {
            Task {
                await relay.stop()
            }
        }
    }

    private func currentPacketWriter() -> (any TunnelPacketWriting)? {
        packetWriterLock.lock()
        let packetWriter = self.packetWriter
        packetWriterLock.unlock()
        return packetWriter
    }
}
