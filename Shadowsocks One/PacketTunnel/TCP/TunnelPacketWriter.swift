import Foundation
@preconcurrency import NetworkExtension

protocol TunnelPacketWriting: AnyObject {
    func write(_ packets: [Data], protocols: [NSNumber])
}

final class TunnelPacketWriter: TunnelPacketWriting {
    private let packetFlow: NEPacketTunnelFlow

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }

    func write(_ packets: [Data], protocols: [NSNumber]) {
        packetFlow.writePackets(packets, withProtocols: protocols)
    }
}
