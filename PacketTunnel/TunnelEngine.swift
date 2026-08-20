import Foundation
@preconcurrency import NetworkExtension
import SharedCore


protocol TunnelPacketFlow: AnyObject {
    func readPackets(completionHandler: @escaping ([Data], [NSNumber]) -> Void)
    func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber])
}

final class PacketTunnelFlowAdapter: TunnelPacketFlow {
    private let packetFlow: NEPacketTunnelFlow

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }

    func readPackets(completionHandler: @escaping ([Data], [NSNumber]) -> Void) {
        packetFlow.readPackets(completionHandler: completionHandler)
    }

    func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) {
        packetFlow.writePackets(packets, withProtocols: protocols)
    }
}

final class TunnelEngine {
    private let dnsCoordinator: any DNSCoordinating
    private let tcpRouter: any TCPRouting
    private let packetFlow: (any TunnelPacketFlow)?
    private let packetWriter: (any TunnelPacketWriting)?
    private var packetReaderTask: Task<Void, Never>?

    init(
        dnsCoordinator: any DNSCoordinating,
        tcpRouter: any TCPRouting,
        packetFlow: (any TunnelPacketFlow)? = nil,
        packetWriter: (any TunnelPacketWriting)? = nil
    ) {
        self.dnsCoordinator = dnsCoordinator
        self.tcpRouter = tcpRouter
        self.packetFlow = packetFlow
        self.packetWriter = packetWriter
    }

    func warmUpDNSCache() async {
        await dnsCoordinator.warmUpWhitelistCache()
    }

    func start(onFatalError: (@Sendable (Error) -> Void)? = nil) {
        guard packetReaderTask == nil, let packetFlow else {
            return
        }

        packetReaderTask = Task { [weak self] in
            guard let self else { return }
            self.tcpRouter.setPacketWriter(self.packetWriter)

            while !Task.isCancelled {
                let packets = await self.readPackets(from: packetFlow)
                if Task.isCancelled {
                    break
                }

                do {
                    for packet in packets {
                        try Task.checkCancellation()
                        do {
                            try await self.handleOutboundPacket(packet)
                        } catch let error as TunnelPacketError {
                            NSLog("TunnelEngine dropped unsupported packet: %@", String(describing: error))
                        } catch let error as TCPFlowStateError {
                            NSLog("TunnelEngine dropped packet after flow state error: %@", String(describing: error))
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    onFatalError?(error)
                    await self.tcpRouter.stopAll()
                    break
                }
            }

            self.tcpRouter.setPacketWriter(nil)
        }
    }

    func handleOutboundPacket(_ data: Data) async throws {
        let packet = try IPPacket(data: data)

        switch packet.protocolNumber {
        case 17:
            let udp = try packet.udpSegment()
            if udp.destinationPort == 53 || udp.sourcePort == 53 {
                do {
                    try await dnsCoordinator.handle(packet)
                } catch {
                    NSLog("TunnelEngine dropped DNS packet after upstream failure: %@", error.localizedDescription)
                }
            }
        case 6:
            try await tcpRouter.route(packet)
        default:
            return
        }
    }

    func stop() async {
        packetReaderTask?.cancel()
        packetReaderTask = nil
        tcpRouter.setPacketWriter(nil)
        await tcpRouter.stopAll()
    }

    private func readPackets(from packetFlow: any TunnelPacketFlow) async -> [Data] {
        await withCheckedContinuation { continuation in
            packetFlow.readPackets { packets, _ in
                continuation.resume(returning: packets)
            }
        }
    }
}
