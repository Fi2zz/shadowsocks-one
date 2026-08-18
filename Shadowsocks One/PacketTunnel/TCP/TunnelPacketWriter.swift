import Foundation

protocol TunnelPacketWriting: AnyObject {
    func write(_ packets: [Data], protocols: [NSNumber])
}

final class TunnelPacketWriter: TunnelPacketWriting {
    private let packetFlow: any TunnelPacketFlow

    init(packetFlow: any TunnelPacketFlow) {
        self.packetFlow = packetFlow
    }

    func write(_ packets: [Data], protocols: [NSNumber]) {
        packetFlow.writePackets(packets, withProtocols: protocols)
    }
}
