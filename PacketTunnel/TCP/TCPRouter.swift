import Foundation
import SharedCore
import Darwin

protocol TCPRouting: AnyObject {
    func route(_ packet: IPPacket) async throws
    func stopAll() async
    func setPacketWriter(_ packetWriter: (any TunnelPacketWriting)?)
}

final class TCPRouter: TCPRouting {
    private static let maximumInboundSegmentSize = 1_460
    private let matcher: RouteMatcher
    private let sessionStore: TCPFlowSessionStore
    private let packetWriterLock = NSLock()
    private var packetWriter: (any TunnelPacketWriting)?
    private let directRelayFactory: RelayFactory
    private let proxyRelayFactory: RelayFactory
    private let hostResolver: HostResolver?
    private let diagnostics: TunnelDiagnosticsLogging?
    private let now: @Sendable () -> Date
    private let retransmitter: TCPRetransmitter

    typealias RelayFactory = @Sendable (TCPFlowKey) throws -> any TCPFlowRelaying
    typealias HostResolver = @Sendable (String) -> String?

    init(
        launchConfiguration: TunnelLaunchConfiguration,
        matcher: RouteMatcher,
        sessionStore: TCPFlowSessionStore = TCPFlowSessionStore(),
        packetWriter: (any TunnelPacketWriting)? = nil,
        directRelayFactory: RelayFactory? = nil,
        proxyRelayFactory: RelayFactory? = nil,
        hostResolver: HostResolver? = nil,
        diagnostics: TunnelDiagnosticsLogging? = nil,
        now: @Sendable @escaping () -> Date = Date.init,
        retransmitTimeout: TimeInterval = 1.0,
        sweepIntervalNanoseconds: UInt64 = 250_000_000
    ) {
        self.matcher = matcher
        self.sessionStore = sessionStore
        self.packetWriter = packetWriter
        self.hostResolver = hostResolver
        self.diagnostics = diagnostics
        self.now = now
        self.retransmitter = TCPRetransmitter(
            sessionStore: sessionStore,
            diagnostics: diagnostics,
            now: now,
            retransmitTimeout: retransmitTimeout,
            sweepIntervalNanoseconds: sweepIntervalNanoseconds
        )
        self.directRelayFactory = directRelayFactory ?? { key in
            try DirectTCPRelay(
                host: key.destinationAddress,
                port: key.destinationPort,
                diagnostics: diagnostics
            )
        }
        self.proxyRelayFactory = proxyRelayFactory ?? { key in
            // 走代理时优先把原始域名交给服务端解析（ATYP=0x03），
            // 避免本地/远程解析结果不一致或污染残余 IP 进到代理链路
            try ShadowsocksTCPRelay(
                launchConfiguration: launchConfiguration,
                destinationHost: hostResolver?(key.destinationAddress) ?? key.destinationAddress,
                destinationPort: key.destinationPort,
                diagnostics: diagnostics
            )
        }
        retransmitter.setPacketWriter(packetWriter)
    }

    func route(_ packet: IPPacket) async throws {
        let tcp = try packet.tcpSegment()
        let key = TCPFlowKey(packet: packet, tcp: tcp)
        let resolvedHost = hostResolver?(packet.destinationAddress)
        let decision = matcher.route(forHost: resolvedHost, ipString: packet.destinationAddress)
        let existingState = sessionStore.state(for: key)
        guard existingState != nil || tcp.isSYN else {
            return
        }
        let session = try sessionStore.session(for: key) {
            diagnostics?(
                "TCP \(decision.rawValue) \(key.destinationAddress):\(key.destinationPort) host=\(resolvedHost ?? "-")"
            )
            let relay: any TCPFlowRelaying
            switch decision {
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
                do {
                    try await self?.handleInboundBytes(data, for: key)
                } catch {
                    self?.diagnostics?(
                        "TCP inbound drop \(key.destinationAddress):\(key.destinationPort): \(error.localizedDescription)"
                    )
                }
            }
            relay.onClosed = { [weak self] in
                await self?.handleRelayClosed(for: key)
            }
            return (relay, state)
        }

        if tcp.isACK {
            let acknowledged = sessionStore.acknowledgeSentBytes(
                upTo: tcp.acknowledgmentNumber,
                for: key
            )
            retransmitter.recordAcknowledgedSegments(acknowledged, now: now())
        }

        let relay = session.relay
        var state = session.state
        guard state.phase != .initial || tcp.isSYN || tcp.isRST else {
            let activeRelay = sessionStore.removeRelay(for: key) ?? relay
            await activeRelay.stop()
            return
        }
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
                let payloadStartSequence = tcp.sequenceNumber
                let payloadEndSequence = payloadStartSequence &+ UInt32(tcp.payload.count)

                if payloadEndSequence <= state.nextExpectedClientSequence {
                    try writeResponse(
                        TCPFlowResponse(
                            flags: [.ack],
                            sequenceNumber: state.localSequenceNumber,
                            acknowledgmentNumber: state.nextExpectedClientSequence,
                            payload: Data()
                        ),
                        for: state
                    )
                    return
                }

                guard payloadStartSequence == state.nextExpectedClientSequence else {
                    try writeResponse(
                        TCPFlowResponse(
                            flags: [.ack],
                            sequenceNumber: state.localSequenceNumber,
                            acknowledgmentNumber: state.nextExpectedClientSequence,
                            payload: Data()
                        ),
                        for: state
                    )
                    return
                }

                let response = try state.consumeOutboundPayload(tcp.payload.count)
                try writeResponse(response, for: state)
                sessionStore.updateState(state, for: key)
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
        retransmitter.stop()
        let relays = sessionStore.removeAllRelays()
        for relay in relays {
            await relay.stop()
        }
    }

    func setPacketWriter(_ packetWriter: (any TunnelPacketWriting)?) {
        packetWriterLock.lock()
        self.packetWriter = packetWriter
        packetWriterLock.unlock()
        retransmitter.setPacketWriter(packetWriter)
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

        for chunk in data.chunked(maxBytes: Self.maximumInboundSegmentSize) {
            let response = try state.consumeInboundPayload(chunk)
            try writeResponse(response, for: state)
            sessionStore.recordSentSegment(
                sequenceNumber: response.sequenceNumber,
                payload: chunk,
                for: key,
                now: now()
            )
            sessionStore.updateState(state, for: key)
        }
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

private extension Data {
    func chunked(maxBytes: Int) -> [Data] {
        guard count > maxBytes else {
            return [self]
        }

        var chunks: [Data] = []
        chunks.reserveCapacity((count + maxBytes - 1) / maxBytes)

        var startIndex = 0
        while startIndex < count {
            let endIndex = Swift.min(startIndex + maxBytes, count)
            chunks.append(subdata(in: startIndex..<endIndex))
            startIndex = endIndex
        }

        return chunks
    }
}
