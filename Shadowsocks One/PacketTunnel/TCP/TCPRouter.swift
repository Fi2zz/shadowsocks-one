import Foundation
import SharedCore
import Darwin

protocol TCPRouting: AnyObject {
    func route(_ packet: IPPacket) async throws
    func stopAll() async
    func setPacketWriter(_ packetWriter: (any TunnelPacketWriting)?)
}

final class TCPRouter: TCPRouting {
    private let matcher: RouteMatcher
    private let sessionStore: TCPFlowSessionStore
    private let packetWriterLock = NSLock()
    private var packetWriter: (any TunnelPacketWriting)?
    private let directRelayFactory: RelayFactory
    private let proxyRelayFactory: RelayFactory

    typealias RelayFactory = @Sendable (TCPFlowKey) throws -> any TCPFlowRelaying

    init(
        launchConfiguration: TunnelLaunchConfiguration,
        matcher: RouteMatcher,
        sessionStore: TCPFlowSessionStore = TCPFlowSessionStore(),
        packetWriter: (any TunnelPacketWriting)? = nil,
        directRelayFactory: RelayFactory? = nil,
        proxyRelayFactory: RelayFactory? = nil
    ) {
        self.matcher = matcher
        self.sessionStore = sessionStore
        self.packetWriter = packetWriter
        self.directRelayFactory = directRelayFactory ?? { key in
            try DirectTCPRelay(
                host: key.destinationAddress,
                port: key.destinationPort
            )
        }
        self.proxyRelayFactory = proxyRelayFactory ?? { key in
            try ShadowsocksTCPRelay(
                launchConfiguration: launchConfiguration,
                destinationHost: key.destinationAddress,
                destinationPort: key.destinationPort
            )
        }
    }

    func route(_ packet: IPPacket) async throws {
        let tcp = try packet.tcpSegment()
        let key = TCPFlowKey(packet: packet, tcp: tcp)
        let session = try sessionStore.session(for: key) {
            let relay: any TCPFlowRelaying
            switch matcher.route(forHost: nil, ipString: packet.destinationAddress) {
            case .direct:
                relay = try directRelayFactory(key)
            case .proxy:
                relay = try proxyRelayFactory(key)
            }

            let state = TCPFlowState.initial(
                clientIP: packet.sourceAddress,
                clientPort: tcp.sourcePort,
                remoteIP: packet.destinationAddress,
                remotePort: tcp.destinationPort,
                clientSequenceNumber: tcp.sequenceNumber
            )
            relay.onInboundBytes = { [weak self] data in
                try? await self?.handleInboundBytes(data, for: key)
            }
            relay.onClosed = { [weak self] in
                await self?.handleRelayClosed(for: key)
            }
            return (relay, state)
        }

        let relay = session.relay
        var state = session.state
        do {
            if session.isNew {
                try await relay.start()
            }

            try await handleOutboundControlPacket(
                tcp,
                state: &state,
                key: key
            )

            if !tcp.payload.isEmpty {
                try await relay.forwardOutboundPayload(tcp.payload)
                sessionStore.updateState(state, for: key)
            }

            if tcp.isFIN || tcp.isRST {
                let activeRelay = sessionStore.removeRelay(for: key) ?? relay
                await activeRelay.stop()
            }
        } catch {
            let activeRelay = sessionStore.removeRelay(for: key) ?? relay
            await activeRelay.stop()
            throw error
        }
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

    private func handleOutboundControlPacket(
        _ tcp: TCPPacket,
        state: inout TCPFlowState,
        key: TCPFlowKey
    ) async throws {
        let response: TCPFlowResponse?
        if tcp.isRST {
            response = try state.consumeOutboundRST()
        } else if tcp.isSYN {
            response = try state.consumeOutboundSYN()
        } else if tcp.isFIN, state.phase != .initial {
            response = try state.consumeOutboundFIN()
        } else if tcp.isACK && tcp.payload.isEmpty && state.phase == .synReceived {
            response = try state.consumeOutboundACK()
        } else {
            response = nil
        }

        guard let response else {
            return
        }

        try writeResponse(response, for: state)
        sessionStore.updateState(state, for: key)
    }

    private func handleInboundBytes(_ data: Data, for key: TCPFlowKey) async throws {
        guard var state = sessionStore.state(for: key) else {
            return
        }

        let response = try state.consumeInboundPayload(data)
        try writeResponse(response, for: state)
        sessionStore.updateState(state, for: key)
    }

    private func handleRelayClosed(for key: TCPFlowKey) async {
        guard var state = sessionStore.state(for: key) else {
            return
        }

        guard state.phase == .established || state.phase == .synReceived else {
            _ = sessionStore.removeRelay(for: key)
            return
        }

        do {
            let response = try state.consumeOutboundFIN()
            try writeResponse(response, for: state)
        } catch {
            do {
                let response = try state.consumeOutboundRST()
                try writeResponse(response, for: state)
            } catch {
            }
        }

        _ = sessionStore.removeRelay(for: key)
    }

    private func writeResponse(_ response: TCPFlowResponse, for state: TCPFlowState) throws {
        guard let packetWriter = currentPacketWriter() else {
            return
        }

        let packet = try TCPPacketBuilder.build(
            sourceIP: state.remoteIP,
            sourcePort: state.remotePort,
            destinationIP: state.clientIP,
            destinationPort: state.clientPort,
            sequenceNumber: response.sequenceNumber,
            acknowledgmentNumber: response.acknowledgmentNumber,
            flags: response.flags,
            payload: response.payload
        )

        packetWriter.write([packet], protocols: [NSNumber(value: AF_INET)])
    }

    private func currentPacketWriter() -> (any TunnelPacketWriting)? {
        packetWriterLock.lock()
        let packetWriter = self.packetWriter
        packetWriterLock.unlock()
        return packetWriter
    }
}
