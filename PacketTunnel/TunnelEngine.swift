import Foundation
@preconcurrency import NetworkExtension
import SharedCore

// #region debug-point instrumentation:reporter
enum TunnelDebugReporter {
    private static let serverURL = URL(string: "http://192.168.0.136:7777/event")
    private static let enabled = UserDefaults(
        suiteName: SharedContainerSettings.appGroupID
    )?.bool(forKey: "tunnelDebugEnabled") ?? false

    static func send(
        _ hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:]
    ) {
        guard enabled else {
            return
        }

        guard let serverURL,
              let body = try? JSONSerialization.data(
                withJSONObject: [
                    "sessionId": "vpn-webpage-blocked",
                    "runId": "post-fix",
                    "hypothesisId": hypothesisId,
                    "location": location,
                    "msg": "[DEBUG] \(message)",
                    "data": data,
                    "ts": Int(Date().timeIntervalSince1970 * 1000),
                ]
              ) else {
            return
        }

        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request).resume()
    }
}
// #endregion

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

        // #region debug-point D:engine-start
        TunnelDebugReporter.send(
            "D",
            location: "TunnelEngine.start",
            message: "packet read loop starting"
        )
        // #endregion
        packetReaderTask = Task { [weak self] in
            guard let self else { return }
            self.tcpRouter.setPacketWriter(self.packetWriter)

            while !Task.isCancelled {
                let packets = await self.readPackets(from: packetFlow)
                // #region debug-point D:packet-batch
                TunnelDebugReporter.send(
                    "D",
                    location: "TunnelEngine.start",
                    message: "packet batch received",
                    data: ["packetCount": packets.count]
                )
                // #endregion
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

        // #region debug-point D:packet-dispatch
        TunnelDebugReporter.send(
            "D",
            location: "TunnelEngine.handleOutboundPacket",
            message: "dispatching outbound packet",
            data: [
                "protocol": packet.protocolNumber,
                "sourceIP": packet.sourceAddress,
                "destinationIP": packet.destinationAddress,
                "totalLength": packet.totalLength,
            ]
        )
        // #endregion
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
