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

    typealias RelayFactory = @Sendable (TCPFlowKey) throws -> any TCPFlowRelaying
    typealias HostResolver = @Sendable (String) -> String?

    init(
        launchConfiguration: TunnelLaunchConfiguration,
        matcher: RouteMatcher,
        sessionStore: TCPFlowSessionStore = TCPFlowSessionStore(),
        packetWriter: (any TunnelPacketWriting)? = nil,
        directRelayFactory: RelayFactory? = nil,
        proxyRelayFactory: RelayFactory? = nil,
        hostResolver: HostResolver? = nil
    ) {
        self.matcher = matcher
        self.sessionStore = sessionStore
        self.packetWriter = packetWriter
        self.hostResolver = hostResolver
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
        let resolvedHost = hostResolver?(packet.destinationAddress)
        let decision = matcher.route(forHost: resolvedHost, ipString: packet.destinationAddress)
        let existingState = sessionStore.state(for: key)
        // #region debug-point B:tcp-route-entry
        TunnelDebugReporter.send(
            "B",
            location: "TCPRouter.route",
            message: "routing TCP packet",
            data: [
                "clientIP": packet.sourceAddress,
                "clientPort": tcp.sourcePort,
                "remoteIP": packet.destinationAddress,
                "remotePort": tcp.destinationPort,
                "isSYN": tcp.isSYN,
                "isACK": tcp.isACK,
                "isFIN": tcp.isFIN,
                "isRST": tcp.isRST,
                "payloadBytes": tcp.payload.count,
                "resolvedHost": resolvedHost ?? "",
                "decision": String(describing: decision),
            ]
        )
        // #endregion
        guard existingState != nil || tcp.isSYN else {
            // #region debug-point B:tcp-drop-stray-packet
            TunnelDebugReporter.send(
                "B",
                location: "TCPRouter.route",
                message: "dropping tcp packet without active session",
                data: [
                    "clientIP": packet.sourceAddress,
                    "clientPort": tcp.sourcePort,
                    "remoteIP": packet.destinationAddress,
                    "remotePort": tcp.destinationPort,
                    "isACK": tcp.isACK,
                    "isFIN": tcp.isFIN,
                    "isRST": tcp.isRST,
                    "payloadBytes": tcp.payload.count,
                ]
            )
            // #endregion
            return
        }
        let session = try sessionStore.session(for: key) {
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
                try? await self?.handleInboundBytes(data, for: key)
            }
            relay.onClosed = { [weak self] in
                await self?.handleRelayClosed(for: key)
            }
            return (relay, state)
        }

        let relay = session.relay
        var state = session.state
        // #region debug-point B:tcp-session-state
        TunnelDebugReporter.send(
            "B",
            location: "TCPRouter.route",
            message: "tcp session loaded",
            data: [
                "isNew": session.isNew,
                "phase": String(describing: state.phase),
                "nextExpectedClientSequence": state.nextExpectedClientSequence,
                "localSequenceNumber": state.localSequenceNumber,
            ]
        )
        // #endregion
        guard state.phase != .initial || tcp.isSYN || tcp.isRST else {
            let activeRelay = sessionStore.removeRelay(for: key) ?? relay
            await activeRelay.stop()
            // #region debug-point B:tcp-drop-initial-nonsyn
            TunnelDebugReporter.send(
                "B",
                location: "TCPRouter.route",
                message: "dropping non-syn packet for initial tcp session",
                data: [
                    "clientIP": packet.sourceAddress,
                    "clientPort": tcp.sourcePort,
                    "remoteIP": packet.destinationAddress,
                    "remotePort": tcp.destinationPort,
                    "isNew": session.isNew,
                    "payloadBytes": tcp.payload.count,
                    "isACK": tcp.isACK,
                    "isFIN": tcp.isFIN,
                    "isRST": tcp.isRST,
                ]
            )
            // #endregion
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
                    // #region debug-point B:tcp-duplicate-payload
                    TunnelDebugReporter.send(
                        "B",
                        location: "TCPRouter.route",
                        message: "dropping duplicate outbound payload",
                        data: [
                            "payloadBytes": tcp.payload.count,
                            "payloadStartSequence": payloadStartSequence,
                            "payloadEndSequence": payloadEndSequence,
                            "nextExpectedClientSequence": state.nextExpectedClientSequence,
                            "localSequenceNumber": state.localSequenceNumber,
                        ]
                    )
                    // #endregion
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
                    // #region debug-point B:tcp-out-of-order-payload
                    TunnelDebugReporter.send(
                        "B",
                        location: "TCPRouter.route",
                        message: "dropping out-of-order outbound payload",
                        data: [
                            "payloadBytes": tcp.payload.count,
                            "payloadStartSequence": payloadStartSequence,
                            "payloadEndSequence": payloadEndSequence,
                            "nextExpectedClientSequence": state.nextExpectedClientSequence,
                            "localSequenceNumber": state.localSequenceNumber,
                        ]
                    )
                    // #endregion
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

                // #region debug-point B:tcp-outbound-payload-before
                TunnelDebugReporter.send(
                    "B",
                    location: "TCPRouter.route",
                    message: "consuming outbound payload",
                    data: [
                        "payloadBytes": tcp.payload.count,
                        "phase": String(describing: state.phase),
                        "localSequenceNumber": state.localSequenceNumber,
                        "nextExpectedClientSequence": state.nextExpectedClientSequence,
                    ]
                )
                // #endregion
                let response = try state.consumeOutboundPayload(tcp.payload.count)
                // #region debug-point B:tcp-outbound-payload-after
                TunnelDebugReporter.send(
                    "B",
                    location: "TCPRouter.route",
                    message: "outbound payload consumed",
                    data: [
                        "payloadBytes": tcp.payload.count,
                        "phase": String(describing: state.phase),
                        "localSequenceNumber": state.localSequenceNumber,
                        "nextExpectedClientSequence": state.nextExpectedClientSequence,
                    ]
                )
                // #endregion
                try writeResponse(response, for: state)
                sessionStore.updateState(state, for: key)
                try await relay.forwardOutboundPayload(tcp.payload)
                sessionStore.updateState(state, for: key)
                // #region debug-point B:tcp-forwarded-payload
                TunnelDebugReporter.send(
                    "B",
                    location: "TCPRouter.route",
                    message: "forwarded outbound payload to relay",
                    data: [
                        "payloadBytes": tcp.payload.count,
                        "nextExpectedClientSequence": state.nextExpectedClientSequence,
                    ]
                )
                // #endregion
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

        // #region debug-point B:tcp-control-response
        TunnelDebugReporter.send(
            "B",
            location: "TCPRouter.handleOutboundControlPacket",
            message: "writing TCP control response",
            data: [
                "phase": String(describing: state.phase),
                "flags": response.flags.map(\.rawValue).sorted(),
                "payloadBytes": response.payload.count,
            ]
        )
        // #endregion
        try writeResponse(response, for: state)
        sessionStore.updateState(state, for: key)
    }

    private func handleInboundBytes(_ data: Data, for key: TCPFlowKey) async throws {
        guard var state = sessionStore.state(for: key) else {
            return
        }

        // #region debug-point B:tcp-inbound-bytes
        TunnelDebugReporter.send(
            "B",
            location: "TCPRouter.handleInboundBytes",
            message: "received inbound bytes from relay",
            data: [
                "payloadBytes": data.count,
                "phase": String(describing: state.phase),
                "segmentCount": max(1, (data.count + Self.maximumInboundSegmentSize - 1) / Self.maximumInboundSegmentSize),
            ]
        )
        // #endregion
        for chunk in data.chunked(maxBytes: Self.maximumInboundSegmentSize) {
            // #region debug-point B:tcp-inbound-chunk-before
            TunnelDebugReporter.send(
                "B",
                location: "TCPRouter.handleInboundBytes",
                message: "consuming inbound payload chunk",
                data: [
                    "payloadBytes": chunk.count,
                    "phase": String(describing: state.phase),
                    "localSequenceNumber": state.localSequenceNumber,
                    "nextExpectedClientSequence": state.nextExpectedClientSequence,
                ]
            )
            // #endregion
            let response = try state.consumeInboundPayload(chunk)
            // #region debug-point B:tcp-inbound-chunk-after
            TunnelDebugReporter.send(
                "B",
                location: "TCPRouter.handleInboundBytes",
                message: "inbound payload chunk consumed",
                data: [
                    "payloadBytes": chunk.count,
                    "phase": String(describing: state.phase),
                    "localSequenceNumber": state.localSequenceNumber,
                    "nextExpectedClientSequence": state.nextExpectedClientSequence,
                    "responseSequenceNumber": response.sequenceNumber,
                    "responseAcknowledgmentNumber": response.acknowledgmentNumber,
                    "responseFlags": response.flags.map(\.rawValue).sorted(),
                ]
            )
            // #endregion
            try writeResponse(response, for: state)
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
            // #region debug-point B:tcp-relay-close-state
            TunnelDebugReporter.send(
                "B",
                location: "TCPRouter.handleRelayClosed",
                message: "handling relay close for tcp session",
                data: [
                    "phase": String(describing: state.phase),
                    "localSequenceNumber": state.localSequenceNumber,
                    "nextExpectedClientSequence": state.nextExpectedClientSequence,
                ]
            )
            // #endregion
            let response = try state.consumeOutboundFIN()
            // #region debug-point B:tcp-relay-closed
            TunnelDebugReporter.send(
                "B",
                location: "TCPRouter.handleRelayClosed",
                message: "relay closed and FIN response generated",
                data: ["phase": String(describing: state.phase)]
            )
            // #endregion
            try writeResponse(response, for: state)
        } catch {
            do {
                let response = try state.consumeOutboundRST()
                // #region debug-point B:tcp-relay-reset
                TunnelDebugReporter.send(
                    "B",
                    location: "TCPRouter.handleRelayClosed",
                    message: "relay closed and RST response generated",
                    data: ["phase": String(describing: state.phase)]
                )
                // #endregion
                try writeResponse(response, for: state)
            } catch {
            }
        }

        _ = sessionStore.removeRelay(for: key)
    }

    private func writeResponse(_ response: TCPFlowResponse, for state: TCPFlowState) throws {
        guard let packetWriter = currentPacketWriter() else {
            // #region debug-point B:tcp-write-response-missing-writer
            TunnelDebugReporter.send(
                "B",
                location: "TCPRouter.writeResponse",
                message: "skipping tcp response because packet writer is unavailable",
                data: [
                    "clientIP": state.clientIP,
                    "clientPort": state.clientPort,
                    "remoteIP": state.remoteIP,
                    "remotePort": state.remotePort,
                    "phase": String(describing: state.phase),
                    "sequenceNumber": response.sequenceNumber,
                    "acknowledgmentNumber": response.acknowledgmentNumber,
                    "flags": response.flags.map(\.rawValue).sorted(),
                    "payloadBytes": response.payload.count,
                ]
            )
            // #endregion
            return
        }

        // #region debug-point B:tcp-write-response
        TunnelDebugReporter.send(
            "B",
            location: "TCPRouter.writeResponse",
            message: "writing tcp response to packet flow",
            data: [
                "clientIP": state.clientIP,
                "clientPort": state.clientPort,
                "remoteIP": state.remoteIP,
                "remotePort": state.remotePort,
                "phase": String(describing: state.phase),
                "sequenceNumber": response.sequenceNumber,
                "acknowledgmentNumber": response.acknowledgmentNumber,
                "flags": response.flags.map(\.rawValue).sorted(),
                "payloadBytes": response.payload.count,
            ]
        )
        // #endregion
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
        // #region debug-point B:tcp-write-response-finished
        TunnelDebugReporter.send(
            "B",
            location: "TCPRouter.writeResponse",
            message: "tcp response written to packet writer",
            data: [
                "clientIP": state.clientIP,
                "clientPort": state.clientPort,
                "remoteIP": state.remoteIP,
                "remotePort": state.remotePort,
                "phase": String(describing: state.phase),
                "sequenceNumber": response.sequenceNumber,
                "acknowledgmentNumber": response.acknowledgmentNumber,
                "flags": response.flags.map(\.rawValue).sorted(),
                "payloadBytes": response.payload.count,
            ]
        )
        // #endregion
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
