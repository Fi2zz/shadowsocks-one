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
        // #region debug-point B:tunnel-packet-writer-write
        TunnelDebugReporter.send(
            "B",
            location: "TunnelPacketWriter.write",
            message: "writing packets to tunnel packet flow",
            data: [
                "packetCount": packets.count,
                "protocolCount": protocols.count,
                "totalBytes": packets.reduce(0) { $0 + $1.count },
            ]
        )
        // #endregion
        packetFlow.writePackets(packets, withProtocols: protocols)
        // #region debug-point B:tunnel-packet-writer-finished
        TunnelDebugReporter.send(
            "B",
            location: "TunnelPacketWriter.write",
            message: "finished writing packets to tunnel packet flow",
            data: [
                "packetCount": packets.count,
                "protocolCount": protocols.count,
                "totalBytes": packets.reduce(0) { $0 + $1.count },
            ]
        )
        // #endregion
    }
}
